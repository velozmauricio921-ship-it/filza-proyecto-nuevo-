//
//  WQWebDAVServer.m
//  FilzaSlop
//
//  Small in-process WebDAV/HTTP server. Filza's stock WebDAV mode launches a
//  root launch daemon; that cannot work in a normally signed app. This server
//  serves the same virtual root using the sandbox extensions consumed by
//  worse_query, entirely inside the Filza process.
//

#import "WQWebDAVServer.h"
#import "MCMFilzaIntegration.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>

#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static NSString *const kWQServerName = @"FilzaSlop WQ";
static const NSInteger kWQDefaultPort = 11111;
static const NSUInteger kWQMaxBodyLength = 1024UL * 1024UL * 1024UL;

static int gListen4 = -1;
static int gListen6 = -1;
static BOOL gRunning;
static NSString *gRootPath;
static NSString *gUsername;
static NSString *gPassword;
static dispatch_queue_t gConnectionQueue;
static NSNetService *gBonjourService;
static NSInteger gBoundPort;
static AVAudioPlayer *gSilentPlayer;
static UIBackgroundTaskIdentifier gBackgroundTask;
static BOOL gBackgroundTaskActive;
static NSObject *gServerLock;

#pragma mark - Small helpers

static NSString *WQHTTPDate(NSDate *date)
{
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
        formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss 'GMT'";
    });
    @synchronized (formatter) {
        return [formatter stringFromDate:date ?: [NSDate date]];
    }
}

static NSString *WQXMLEscape(NSString *text)
{
    NSMutableString *value = [text mutableCopy] ?: [NSMutableString string];
    [value replaceOccurrencesOfString:@"&" withString:@"&amp;"
        options:0 range:NSMakeRange(0, value.length)];
    [value replaceOccurrencesOfString:@"<" withString:@"&lt;"
        options:0 range:NSMakeRange(0, value.length)];
    [value replaceOccurrencesOfString:@">" withString:@"&gt;"
        options:0 range:NSMakeRange(0, value.length)];
    [value replaceOccurrencesOfString:@"\"" withString:@"&quot;"
        options:0 range:NSMakeRange(0, value.length)];
    [value replaceOccurrencesOfString:@"'" withString:@"&apos;"
        options:0 range:NSMakeRange(0, value.length)];
    return value;
}

static NSString *WQEncodeComponent(NSString *component)
{
    NSCharacterSet *allowed = [NSCharacterSet
        characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@"];
    return [component stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: component;
}

static NSString *WQEncodeHref(NSString *relativePath, BOOL directory)
{
    if (relativePath.length == 0) return directory ? @"/" : @"/";
    NSMutableArray *components = [NSMutableArray array];
    for (NSString *component in [relativePath componentsSeparatedByString:@"/"]) {
        if (component.length == 0) continue;
        [components addObject:WQEncodeComponent(component)];
    }
    NSString *encoded = [components componentsJoinedByString:@"/"];
    if (directory) encoded = [encoded stringByAppendingString:@"/"];
    return [@"/" stringByAppendingString:encoded];
}

static NSString *WQRelativePath(NSString *absolutePath)
{
    NSString *root = gRootPath;
    if (!root.length) return absolutePath.lastPathComponent ?: @"";
    if ([absolutePath isEqualToString:root]) return @"";
    NSString *prefix = [root stringByAppendingString:@"/"];
    if ([absolutePath hasPrefix:prefix])
        return [absolutePath substringFromIndex:prefix.length];
    return absolutePath.lastPathComponent ?: @"";
}

static NSString *WQMimeType(NSString *path)
{
    static NSDictionary<NSString *, NSString *> *types;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        types = @{
            @"html": @"text/html; charset=utf-8", @"htm": @"text/html; charset=utf-8",
            @"txt": @"text/plain; charset=utf-8", @"log": @"text/plain; charset=utf-8",
            @"md": @"text/markdown; charset=utf-8",
            @"css": @"text/css; charset=utf-8", @"js": @"application/javascript",
            @"json": @"application/json", @"xml": @"application/xml",
            @"plist": @"application/x-plist", @"mobileprovision": @"application/octet-stream",
            @"png": @"image/png", @"jpg": @"image/jpeg", @"jpeg": @"image/jpeg",
            @"gif": @"image/gif", @"heic": @"image/heic", @"heif": @"image/heif",
            @"webp": @"image/webp", @"svg": @"image/svg+xml",
            @"pdf": @"application/pdf", @"zip": @"application/zip",
            @"gz": @"application/gzip", @"tgz": @"application/gzip",
            @"tar": @"application/x-tar", @"deb": @"application/x-debian-package",
            @"mp3": @"audio/mpeg", @"m4a": @"audio/mp4", @"wav": @"audio/wav",
            @"mp4": @"video/mp4", @"mov": @"video/quicktime", @"m4v": @"video/x-m4v",
            @"dylib": @"application/octet-stream", @"framework": @"application/octet-stream",
            @"sqlite": @"application/vnd.sqlite3", @"db": @"application/vnd.sqlite3",
        };
    });
    return types[path.pathExtension.lowercaseString] ?: @"application/octet-stream";
}

static NSString *WQStatusText(NSInteger status)
{
    switch (status) {
        case 200: return @"OK";
        case 201: return @"Created";
        case 204: return @"No Content";
        case 206: return @"Partial Content";
        case 207: return @"Multi-Status";
        case 301: return @"Moved Permanently";
        case 400: return @"Bad Request";
        case 401: return @"Unauthorized";
        case 403: return @"Forbidden";
        case 404: return @"Not Found";
        case 405: return @"Method Not Allowed";
        case 409: return @"Conflict";
        case 412: return @"Precondition Failed";
        case 416: return @"Range Not Satisfiable";
        case 423: return @"Locked";
        case 500: return @"Internal Server Error";
        case 501: return @"Not Implemented";
        case 507: return @"Insufficient Storage";
        default: return @"Error";
    }
}

static NSString *WQPrimaryIPv4(void)
{
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return nil;
    NSString *fallback = nil;
    for (struct ifaddrs *cursor = interfaces; cursor; cursor = cursor->ifa_next) {
        if (!cursor->ifa_addr || cursor->ifa_addr->sa_family != AF_INET) continue;
        NSString *name = [NSString stringWithUTF8String:cursor->ifa_name ?: ""];
        if ([name isEqualToString:@"lo0"]) continue;
        char address[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *sin = (struct sockaddr_in *)cursor->ifa_addr;
        if (!inet_ntop(AF_INET, &sin->sin_addr, address, sizeof(address))) continue;
        NSString *value = [NSString stringWithUTF8String:address];
        if (!value.length) continue;
        if ([name isEqualToString:@"en0"] || [name isEqualToString:@"en1"])
            return value;
        if (!fallback && ![value hasPrefix:@"169.254."]) fallback = value;
    }
    freeifaddrs(interfaces);
    return fallback;
}

NSInteger WQWebDAVPort(void)
{
    id value = [NSUserDefaults.standardUserDefaults objectForKey:@"air-port"];
    if (!value) {
        Class prefsClass = NSClassFromString(@"TGPreferences");
        id prefs = [prefsClass respondsToSelector:NSSelectorFromString(@"sharedInstance")]
            ? ((id(*)(id, SEL))objc_msgSend)(prefsClass,
                NSSelectorFromString(@"sharedInstance")) : nil;
        if ([prefs respondsToSelector:NSSelectorFromString(@"objectForPreferenceKey:")])
            value = ((id(*)(id, SEL, id))objc_msgSend)(prefs,
                NSSelectorFromString(@"objectForPreferenceKey:"), @"air-port");
    }
    NSInteger port = [value respondsToSelector:@selector(integerValue)]
        ? [value integerValue] : kWQDefaultPort;
    if (port < 1024 || port > 65535) port = kWQDefaultPort;
    return port;
}

NSString *WQWebDAVURL(void)
{
    NSString *ip = WQPrimaryIPv4() ?: @"127.0.0.1";
    NSInteger port = gBoundPort > 0 ? gBoundPort : WQWebDAVPort();
    return [NSString stringWithFormat:@"http://%@:%ld/", ip, (long)port];
}

BOOL WQWebDAVIsRunning(void)
{
    return gRunning && (gListen4 >= 0 || gListen6 >= 0);
}

#pragma mark - Socket reader

@interface WQSocketReader : NSObject
@property (nonatomic) int descriptor;
@property (nonatomic, strong) NSMutableData *buffer;
@end

@implementation WQSocketReader

- (instancetype)initWithDescriptor:(int)descriptor
{
    self = [super init];
    if (!self) return nil;
    _descriptor = descriptor;
    _buffer = [NSMutableData data];
    return self;
}

- (BOOL)fill
{
    uint8_t chunk[65536];
    ssize_t got = recv(self.descriptor, chunk, sizeof(chunk), 0);
    if (got <= 0) return NO;
    [self.buffer appendBytes:chunk length:(NSUInteger)got];
    return YES;
}

- (NSData *)readUntil:(NSData *)delimiter
{
    while (YES) {
        NSRange range = [self.buffer rangeOfData:delimiter
            options:0 range:NSMakeRange(0, self.buffer.length)];
        if (range.location != NSNotFound) {
            NSData *value = [self.buffer subdataWithRange:
                NSMakeRange(0, range.location)];
            NSUInteger consumed = NSMaxRange(range);
            [self.buffer replaceBytesInRange:NSMakeRange(0, consumed)
                                   withBytes:NULL length:0];
            return value;
        }
        if (![self fill]) return nil;
    }
}

- (NSData *)readExact:(NSUInteger)length
{
    while (self.buffer.length < length) {
        if (![self fill]) return nil;
    }
    NSData *value = [self.buffer subdataWithRange:NSMakeRange(0, length)];
    [self.buffer replaceBytesInRange:NSMakeRange(0, length)
                           withBytes:NULL length:0];
    return value;
}

@end

#pragma mark - Request

@interface WQHTTPRequest : NSObject
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *rawPath;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, strong) NSData *body;
@end

@implementation WQHTTPRequest
@end

static NSData *WQCRLF(void)
{
    static NSData *value;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        value = [@"\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    });
    return value;
}

static NSData *WQHeaderDelimiter(void)
{
    static NSData *value;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        value = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    });
    return value;
}

#pragma mark - Responses

static void WQSendAll(int descriptor, const void *bytes, NSUInteger length)
{
    const uint8_t *cursor = bytes;
    NSUInteger remaining = length;
    while (remaining > 0) {
        ssize_t sent = send(descriptor, cursor, remaining, 0);
        if (sent <= 0) {
            if (errno == EINTR) continue;
            break;
        }
        cursor += sent;
        remaining -= (NSUInteger)sent;
    }
}

static void WQRespond(int descriptor, NSInteger status,
                      NSDictionary<NSString *, NSString *> *extraHeaders,
                      NSData *body, NSInteger contentLengthOverride)
{
    NSMutableString *head = [NSMutableString stringWithFormat:
        @"HTTP/1.1 %ld %@\r\n", (long)status, WQStatusText(status)];
    [head appendFormat:@"Date: %@\r\n", WQHTTPDate([NSDate date])];
    [head appendFormat:@"Server: %@\r\n", kWQServerName];
    [head appendString:@"Connection: close\r\n"];
    [head appendString:@"Accept-Ranges: bytes\r\n"];

    BOOL hasLength = NO;
    for (NSString *key in extraHeaders) {
        if ([key caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame)
            hasLength = YES;
        [head appendFormat:@"%@: %@\r\n", key, extraHeaders[key]];
    }
    if (!hasLength) {
        NSInteger length = contentLengthOverride >= 0
            ? contentLengthOverride : (NSInteger)body.length;
        [head appendFormat:@"Content-Length: %ld\r\n", (long)length];
    }
    [head appendString:@"\r\n"];

    NSData *headData = [head dataUsingEncoding:NSUTF8StringEncoding];
    WQSendAll(descriptor, headData.bytes, headData.length);
    if (body.length > 0)
        WQSendAll(descriptor, body.bytes, body.length);
}

#pragma mark - Path handling

static NSString *WQResolvePath(NSString *requestPath)
{
    NSString *decoded = [requestPath stringByRemovingPercentEncoding] ?: requestPath;
    if (![decoded hasPrefix:@"/"]) return nil;
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    for (NSString *component in [decoded componentsSeparatedByString:@"/"]) {
        if (component.length == 0 || [component isEqualToString:@"."]) continue;
        if ([component isEqualToString:@".."]) {
            if (components.count > 0) [components removeLastObject];
            continue;
        }
        [components addObject:component];
    }
    NSString *relative = [components componentsJoinedByString:@"/"];
    if (relative.length == 0) return gRootPath;
    return [gRootPath stringByAppendingPathComponent:relative];
}

static BOOL WQFileIsDirectory(NSString *path)
{
    BOOL directory = NO;
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:path
                                                    isDirectory:&directory];
    return exists && directory;
}

static NSDictionary<NSString *, NSString *> *WQBasicHeaders(NSString *contentType)
{
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    headers[@"Content-Type"] = contentType ?: @"text/plain; charset=utf-8";
    return headers;
}

#pragma mark - Request body

static NSData *WQReadRequestBody(WQSocketReader *reader, WQHTTPRequest *request)
{
    NSString *transferEncoding = request.headers[@"transfer-encoding"];
    if ([transferEncoding.lowercaseString containsString:@"chunked"]) {
        NSMutableData *body = [NSMutableData data];
        while (YES) {
            NSData *lineData = [reader readUntil:WQCRLF()];
            if (!lineData) return nil;
            NSString *line = [[NSString alloc] initWithData:lineData
                encoding:NSISOLatin1StringEncoding];
            NSString *sizePart = [[line componentsSeparatedByString:@";"] firstObject];
            unsigned long long size = 0;
            NSScanner *scanner = [NSScanner scannerWithString:sizePart ?: @""];
            if (![scanner scanHexLongLong:&size]) return nil;
            if (size == 0) {
                // Consume trailers until an empty line.
                while (YES) {
                    NSData *trailer = [reader readUntil:WQCRLF()];
                    if (!trailer) return nil;
                    if (trailer.length == 0) break;
                }
                break;
            }
            if (body.length + size > kWQMaxBodyLength) return nil;
            NSData *chunk = [reader readExact:(NSUInteger)size];
            if (!chunk) return nil;
            [body appendData:chunk];
            NSData *crlf = [reader readExact:2];
            if (!crlf) return nil;
        }
        return body;
    }

    NSString *lengthValue = request.headers[@"content-length"];
    if (!lengthValue.length) return [NSData data];
    long long length = lengthValue.longLongValue;
    if (length <= 0) return [NSData data];
    if ((unsigned long long)length > kWQMaxBodyLength) return nil;
    return [reader readExact:(NSUInteger)length];
}

#pragma mark - WebDAV methods

static NSString *WQPropResponse(NSString *path, BOOL isDirectory)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attributes = [fm attributesOfItemAtPath:path error:nil];
    NSDate *modified = attributes[NSFileModificationDate] ?: [NSDate date];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    NSString *relative = WQRelativePath(path);
    NSString *href = WQEncodeHref(relative, isDirectory);
    NSString *displayName = relative.length == 0
        ? (gRootPath.lastPathComponent ?: @"FilzaSlop") : path.lastPathComponent;

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<D:response>"];
    [xml appendFormat:@"<D:href>%@</D:href>", WQXMLEscape(href)];
    [xml appendString:@"<D:propstat><D:prop>"];
    [xml appendFormat:@"<D:displayname>%@</D:displayname>",
        WQXMLEscape(displayName)];
    [xml appendString:@"<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/>"
        @"</D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry>"
        @"</D:supportedlock><D:lockdiscovery/>"];
    [xml appendFormat:@"<D:getlastmodified>%@</D:getlastmodified>",
        WQHTTPDate(modified)];
    if (isDirectory) {
        [xml appendString:@"<D:resourcetype><D:collection/></D:resourcetype>"];
        [xml appendString:@"<D:getcontenttype>httpd/unix-directory</D:getcontenttype>"];
    } else {
        [xml appendString:@"<D:resourcetype/>"];
        [xml appendFormat:@"<D:getcontentlength>%llu</D:getcontentlength>", size];
        [xml appendFormat:@"<D:getcontenttype>%@</D:getcontenttype>",
            WQXMLEscape(WQMimeType(path))];
    }
    [xml appendString:@"</D:prop><D:status>HTTP/1.1 200 OK</D:status>"
        @"</D:propstat></D:response>"];
    return xml;
}

static void WQHandlePropfind(int descriptor, WQHTTPRequest *request,
                             NSString *path)
{
    BOOL exists = NO;
    BOOL directory = WQFileIsDirectory(path);
    exists = [NSFileManager.defaultManager fileExistsAtPath:path];
    if (!exists) {
        WQRespond(descriptor, 404, WQBasicHeaders(@"text/plain"),
                  [@"Not Found" dataUsingEncoding:NSUTF8StringEncoding], -1);
        return;
    }

    NSString *depth = request.headers[@"depth"] ?: @"1";
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithObject:path];
    if (directory && ![depth isEqualToString:@"0"]) {
        NSError *error = nil;
        NSArray<NSString *> *names = [NSFileManager.defaultManager
            contentsOfDirectoryAtPath:path error:&error];
        if (names) {
            for (NSString *name in names)
                [paths addObject:[path stringByAppendingPathComponent:name]];
        } else {
            NSLog(@"[WQWebDAV] PROPFIND listing failed %@: %@",
                  path, error.localizedDescription);
        }
    }

    NSMutableString *xml = [NSMutableString stringWithString:
        @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        @"<D:multistatus xmlns:D=\"DAV:\">"];
    for (NSString *item in paths) {
        BOOL isDirectory = WQFileIsDirectory(item);
        NSDictionary *attributes = [NSFileManager.defaultManager
            attributesOfItemAtPath:item error:nil];
        if (!attributes) continue;
        [xml appendString:WQPropResponse(item, isDirectory)];
    }
    [xml appendString:@"</D:multistatus>"];
    NSData *body = [xml dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *headers = [WQBasicHeaders(
        @"application/xml; charset=utf-8") mutableCopy];
    headers[@"DAV"] = @"1, 2";
    WQRespond(descriptor, 207, headers, body, -1);
}

static void WQHandleGet(int descriptor, WQHTTPRequest *request,
                        NSString *path, BOOL headOnly)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL directory = WQFileIsDirectory(path);
    if (![fm fileExistsAtPath:path]) {
        WQRespond(descriptor, 404, WQBasicHeaders(@"text/plain"),
                  [@"Not Found" dataUsingEncoding:NSUTF8StringEncoding], -1);
        return;
    }

    if (directory) {
        NSError *error = nil;
        NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:path error:&error];
        NSMutableString *html = [NSMutableString stringWithFormat:
            @"<!doctype html><meta name=\"viewport\" content=\"width=device-width\">"
            @"<title>%@</title><h1>%@</h1><ul>",
            WQXMLEscape(WQRelativePath(path) ?: @"/"),
            WQXMLEscape(WQRelativePath(path) ?: @"/")];
        if (!names) {
            [html appendFormat:@"<p>%@</p>", WQXMLEscape(error.localizedDescription ?: @"Unreadable")];
        }
        for (NSString *name in [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
            NSString *child = [path stringByAppendingPathComponent:name];
            BOOL childDirectory = WQFileIsDirectory(child);
            NSString *display = childDirectory ? [name stringByAppendingString:@"/"] : name;
            NSString *relative = WQRelativePath(child);
            NSString *href = WQEncodeHref(relative, childDirectory);
            [html appendFormat:@"<li><a href=\"%@\">%@</a></li>",
                WQXMLEscape(href), WQXMLEscape(display)];
        }
        [html appendString:@"</ul>"];
        NSData *body = [html dataUsingEncoding:NSUTF8StringEncoding];
        WQRespond(descriptor, 200, WQBasicHeaders(@"text/html; charset=utf-8"),
                  headOnly ? nil : body, (NSInteger)body.length);
        return;
    }

    NSDictionary *attributes = [fm attributesOfItemAtPath:path error:nil];
    unsigned long long total = [attributes[NSFileSize] unsignedLongLongValue];
    NSMutableDictionary *headers = [WQBasicHeaders(WQMimeType(path)) mutableCopy];
    headers[@"Accept-Ranges"] = @"bytes";

    NSUInteger start = 0;
    NSUInteger end = total > 0 ? (NSUInteger)(total - 1) : 0;
    BOOL partial = NO;
    NSString *range = request.headers[@"range"];
    if (range.length && [range hasPrefix:@"bytes="]) {
        NSString *spec = [range substringFromIndex:6];
        NSArray *parts = [spec componentsSeparatedByString:@"-"];
        if (parts.count == 2 && ![spec containsString:@","]) {
            NSString *startText = parts[0];
            NSString *endText = parts[1];
            if (startText.length == 0 && endText.length > 0) {
                unsigned long long suffix = endText.longLongValue;
                if (suffix > 0 && suffix <= total) {
                    start = (NSUInteger)(total - suffix);
                    end = (NSUInteger)(total - 1);
                    partial = YES;
                }
            } else if (startText.length > 0) {
                unsigned long long first = startText.longLongValue;
                unsigned long long last = endText.length > 0
                    ? endText.longLongValue : total - 1;
                if (first < total) {
                    start = (NSUInteger)first;
                    end = (NSUInteger)MIN(last, total - 1);
                    partial = YES;
                }
            }
        }
        if (partial && (start > end || start >= total)) {
            headers[@"Content-Range"] = [NSString stringWithFormat:
                @"bytes */%llu", total];
            WQRespond(descriptor, 416, headers, nil, 0);
            return;
        }
    }

    NSInteger length = partial ? (NSInteger)(end - start + 1) : (NSInteger)total;
    if (partial) {
        headers[@"Content-Range"] = [NSString stringWithFormat:
            @"bytes %lu-%lu/%llu", (unsigned long)start,
            (unsigned long)end, total];
    } else {
        start = 0;
        length = (NSInteger)total;
    }

    if (headOnly) {
        WQRespond(descriptor, partial ? 206 : 200, headers, nil, length);
        return;
    }

    NSData *data = [NSData dataWithContentsOfFile:path
        options:NSDataReadingMappedIfSafe error:nil];
    if (!data) {
        WQRespond(descriptor, 500, WQBasicHeaders(@"text/plain"),
                  [@"Unable to read file" dataUsingEncoding:NSUTF8StringEncoding], -1);
        return;
    }
    NSData *body = data;
    if (partial) {
        if (start + (NSUInteger)length > data.length) {
            WQRespond(descriptor, 416, headers, nil, 0);
            return;
        }
        body = [data subdataWithRange:NSMakeRange(start, (NSUInteger)length)];
    }
    WQRespond(descriptor, partial ? 206 : 200, headers, body, -1);
}

static void WQHandlePut(int descriptor, WQHTTPRequest *request,
                        NSString *path)
{
    if (WQFileIsDirectory(path)) {
        WQRespond(descriptor, 405, WQBasicHeaders(@"text/plain"), nil, 0);
        return;
    }
    NSString *parent = path.stringByDeletingLastPathComponent;
    if (!WQFileIsDirectory(parent)) {
        WQRespond(descriptor, 409, WQBasicHeaders(@"text/plain"),
                  [@"Parent does not exist" dataUsingEncoding:NSUTF8StringEncoding], -1);
        return;
    }
    BOOL existed = [NSFileManager.defaultManager fileExistsAtPath:path];
    NSError *error = nil;
    BOOL written = [request.body writeToFile:path options:NSDataWritingAtomic error:&error];
    if (!written) {
        NSLog(@"[WQWebDAV] PUT failed %@: %@", path, error.localizedDescription);
        WQRespond(descriptor, 507, WQBasicHeaders(@"text/plain"),
                  [@"Write failed" dataUsingEncoding:NSUTF8StringEncoding], -1);
        return;
    }
    NSDictionary *attributes = [NSFileManager.defaultManager
        attributesOfItemAtPath:path error:nil];
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    headers[@"ETag"] = [NSString stringWithFormat:@"\"%llx-%llx\"",
        [attributes[NSFileSize] unsignedLongLongValue],
        (unsigned long long)[attributes[NSFileModificationDate] timeIntervalSince1970]];
    WQRespond(descriptor, existed ? 204 : 201, headers, nil, 0);
}

static void WQHandleDelete(int descriptor, NSString *path)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) {
        WQRespond(descriptor, 404, WQBasicHeaders(@"text/plain"), nil, 0);
        return;
    }
    NSError *error = nil;
    if (![fm removeItemAtPath:path error:&error]) {
        NSLog(@"[WQWebDAV] DELETE failed %@: %@", path, error.localizedDescription);
        WQRespond(descriptor, 403, WQBasicHeaders(@"text/plain"),
                  [@"Delete failed" dataUsingEncoding:NSUTF8StringEncoding], -1);
        return;
    }
    WQRespond(descriptor, 204, @{}, nil, 0);
}

static void WQHandleMkcol(int descriptor, NSString *path)
{
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
        WQRespond(descriptor, 405, WQBasicHeaders(@"text/plain"), nil, 0);
        return;
    }
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:path
            withIntermediateDirectories:NO attributes:nil error:&error]) {
        WQRespond(descriptor, 409, WQBasicHeaders(@"text/plain"),
                  [error.localizedDescription dataUsingEncoding:NSUTF8StringEncoding], -1);
        return;
    }
    WQRespond(descriptor, 201, @{}, nil, 0);
}

static void WQHandleMoveCopy(int descriptor, WQHTTPRequest *request,
                             NSString *source, BOOL move)
{
    NSString *destinationHeader = request.headers[@"destination"];
    if (!destinationHeader.length) {
        WQRespond(descriptor, 400, WQBasicHeaders(@"text/plain"), nil, 0);
        return;
    }
    NSString *destinationRequestPath = destinationHeader;
    NSURL *url = [NSURL URLWithString:destinationHeader];
    if (url.path.length) destinationRequestPath = url.path;
    NSString *destination = WQResolvePath(destinationRequestPath);
    if (!destination.length || [destination isEqualToString:source]) {
        WQRespond(descriptor, 403, WQBasicHeaders(@"text/plain"), nil, 0);
        return;
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:source]) {
        WQRespond(descriptor, 404, WQBasicHeaders(@"text/plain"), nil, 0);
        return;
    }
    if (!WQFileIsDirectory(destination.stringByDeletingLastPathComponent)) {
        WQRespond(descriptor, 409, WQBasicHeaders(@"text/plain"), nil, 0);
        return;
    }

    BOOL destinationExists = [NSFileManager.defaultManager
        fileExistsAtPath:destination];
    NSString *overwrite = request.headers[@"overwrite"] ?: @"T";
    if (destinationExists) {
        if ([overwrite.uppercaseString isEqualToString:@"F"]) {
            WQRespond(descriptor, 412, WQBasicHeaders(@"text/plain"), nil, 0);
            return;
        }
        [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
    }

    NSError *error = nil;
    BOOL ok = move
        ? [NSFileManager.defaultManager moveItemAtPath:source toPath:destination error:&error]
        : [NSFileManager.defaultManager copyItemAtPath:source toPath:destination error:&error];
    if (!ok) {
        NSLog(@"[WQWebDAV] %@ failed %@ -> %@: %@", move ? @"MOVE" : @"COPY",
              source, destination, error.localizedDescription);
        WQRespond(descriptor, 409, WQBasicHeaders(@"text/plain"),
                  [error.localizedDescription dataUsingEncoding:NSUTF8StringEncoding], -1);
        return;
    }
    WQRespond(descriptor, destinationExists ? 204 : 201, @{}, nil, 0);
}

static void WQHandleLock(int descriptor, WQHTTPRequest *request, NSString *path)
{
    NSString *token = [NSString stringWithFormat:@"opaquelocktoken:%@",
        NSUUID.UUID.UUIDString];
    NSString *relative = WQRelativePath(path);
    NSString *href = WQEncodeHref(relative, WQFileIsDirectory(path));
    NSString *xml = [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        @"<D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock>"
        @"<D:locktype><D:write/></D:locktype>"
        @"<D:lockscope><D:exclusive/></D:lockscope><D:depth>infinity</D:depth>"
        @"<D:lockroot><D:href>%@</D:href></D:lockroot>"
        @"<D:locktoken><D:href>%@</D:href></D:locktoken>"
        @"<D:timeout>Second-3600</D:timeout>"
        @"</D:activelock></D:lockdiscovery></D:prop>", WQXMLEscape(href),
        WQXMLEscape(token)];
    NSMutableDictionary *headers = [WQBasicHeaders(
        @"application/xml; charset=utf-8") mutableCopy];
    headers[@"Lock-Token"] = [NSString stringWithFormat:@"<%@>", token];
    WQRespond(descriptor, 200, headers,
              [xml dataUsingEncoding:NSUTF8StringEncoding], -1);
}

static void WQHandleProppatch(int descriptor, WQHTTPRequest *request,
                              NSString *path)
{
    NSString *relative = WQRelativePath(path);
    NSString *href = WQEncodeHref(relative, WQFileIsDirectory(path));
    NSString *xml = [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        @"<D:multistatus xmlns:D=\"DAV:\"><D:response>"
        @"<D:href>%@</D:href><D:propstat><D:prop/>"
        @"<D:status>HTTP/1.1 200 OK</D:status></D:propstat>"
        @"</D:response></D:multistatus>", WQXMLEscape(href)];
    WQRespond(descriptor, 207, WQBasicHeaders(@"application/xml; charset=utf-8"),
              [xml dataUsingEncoding:NSUTF8StringEncoding], -1);
}

static void WQHandleOptions(int descriptor)
{
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    headers[@"DAV"] = @"1, 2";
    headers[@"MS-Author-Via"] = @"DAV";
    headers[@"Allow"] = @"OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, "
                        @"MKCOL, COPY, MOVE, LOCK, UNLOCK";
    headers[@"Content-Type"] = @"text/plain";
    WQRespond(descriptor, 200, headers, nil, 0);
}

#pragma mark - Request loop

static BOOL WQCheckAuthentication(WQHTTPRequest *request)
{
    if (!gUsername.length) return YES;
    NSString *authorization = request.headers[@"authorization"];
    if (![authorization hasPrefix:@"Basic "]) return NO;
    NSString *encoded = [authorization substringFromIndex:6];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
    if (!data) return NO;
    NSString *pair = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray *parts = [pair componentsSeparatedByString:@":"];
    if (parts.count < 2) return NO;
    NSString *user = [parts firstObject];
    NSString *password = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)]
        componentsJoinedByString:@":"];
    return [user isEqualToString:gUsername] &&
        [password isEqualToString:gPassword ?: @""];
}

static void WQHandleClient(int descriptor)
{
    @autoreleasepool {
        struct timeval timeout = { 30, 0 };
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        int noSigPipe = 1;
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));

        WQSocketReader *reader = [[WQSocketReader alloc] initWithDescriptor:descriptor];
        NSData *headData = [reader readUntil:WQHeaderDelimiter()];
        if (!headData.length) { close(descriptor); return; }

        NSString *head = [[NSString alloc] initWithData:headData
            encoding:NSUTF8StringEncoding];
        if (!head) head = [[NSString alloc] initWithData:headData
            encoding:NSISOLatin1StringEncoding];
        if (!head) { close(descriptor); return; }

        NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\r\n"];
        if (lines.count == 0) { close(descriptor); return; }
        NSArray<NSString *> *requestLine = [lines[0] componentsSeparatedByString:@" "];
        if (requestLine.count < 2) { close(descriptor); return; }

        WQHTTPRequest *request = [WQHTTPRequest new];
        request.method = requestLine[0].uppercaseString;
        request.rawPath = requestLine[1];
        request.version = requestLine.count > 2 ? requestLine[2] : @"HTTP/1.1";

        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        for (NSUInteger index = 1; index < lines.count; index++) {
            NSString *line = lines[index];
            NSRange colon = [line rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            NSString *key = [[line substringToIndex:colon.location]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                .lowercaseString;
            NSString *value = [[line substringFromIndex:colon.location + 1]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (key.length) headers[key] = value;
        }
        request.headers = headers;

        NSString *pathPart = request.rawPath;
        NSRange query = [pathPart rangeOfString:@"?"];
        if (query.location != NSNotFound) pathPart = [pathPart substringToIndex:query.location];
        NSRange fragment = [pathPart rangeOfString:@"#"];
        if (fragment.location != NSNotFound) pathPart = [pathPart substringToIndex:fragment.location];

        // Read the body only for methods that carry one; a stray huge body on
        // GET would otherwise stall the connection.
        if (![request.method isEqualToString:@"GET"] &&
            ![request.method isEqualToString:@"HEAD"] &&
            ![request.method isEqualToString:@"OPTIONS"] &&
            ![request.method isEqualToString:@"DELETE"] &&
            ![request.method isEqualToString:@"PROPFIND"]) {
            request.body = WQReadRequestBody(reader, request) ?: [NSData data];
        } else {
            request.body = [NSData data];
        }

        if (!WQCheckAuthentication(request)) {
            NSMutableDictionary *authHeaders = [WQBasicHeaders(@"text/plain") mutableCopy];
            authHeaders[@"WWW-Authenticate"] =
                @"Basic realm=\"FilzaSlop WebDAV\"";
            WQRespond(descriptor, 401, authHeaders,
                      [@"Authentication required" dataUsingEncoding:NSUTF8StringEncoding], -1);
            close(descriptor);
            return;
        }

        if ([request.method isEqualToString:@"OPTIONS"]) {
            WQHandleOptions(descriptor);
            close(descriptor);
            return;
        }

        NSString *path = WQResolvePath(pathPart);
        if (!path.length) {
            WQRespond(descriptor, 400, WQBasicHeaders(@"text/plain"), nil, 0);
            close(descriptor);
            return;
        }

        NSInteger logStatus = 0;
        if ([request.method isEqualToString:@"PROPFIND"]) {
            WQHandlePropfind(descriptor, request, path);
        } else if ([request.method isEqualToString:@"GET"]) {
            WQHandleGet(descriptor, request, path, NO);
        } else if ([request.method isEqualToString:@"HEAD"]) {
            WQHandleGet(descriptor, request, path, YES);
        } else if ([request.method isEqualToString:@"PUT"]) {
            WQHandlePut(descriptor, request, path);
        } else if ([request.method isEqualToString:@"DELETE"]) {
            WQHandleDelete(descriptor, path);
        } else if ([request.method isEqualToString:@"MKCOL"]) {
            WQHandleMkcol(descriptor, path);
        } else if ([request.method isEqualToString:@"MOVE"]) {
            WQHandleMoveCopy(descriptor, request, path, YES);
        } else if ([request.method isEqualToString:@"COPY"]) {
            WQHandleMoveCopy(descriptor, request, path, NO);
        } else if ([request.method isEqualToString:@"LOCK"]) {
            WQHandleLock(descriptor, request, path);
        } else if ([request.method isEqualToString:@"UNLOCK"]) {
            WQRespond(descriptor, 204, @{}, nil, 0);
        } else if ([request.method isEqualToString:@"PROPPATCH"]) {
            WQHandleProppatch(descriptor, request, path);
        } else {
            WQRespond(descriptor, 405, WQBasicHeaders(@"text/plain"), nil, 0);
        }
        (void)logStatus;
        close(descriptor);
    }
}

static void *WQAcceptLoop(void *context)
{
    int listener = (int)(intptr_t)context;
    while (gRunning) {
        int client = accept(listener, NULL, NULL);
        if (client < 0) {
            if (!gRunning) break;
            if (errno == EINTR) continue;
            if (errno == EBADF || errno == EINVAL) break;
            usleep(10000);
            continue;
        }
        dispatch_async(gConnectionQueue, ^{
            WQHandleClient(client);
        });
    }
    return NULL;
}

static int WQCreateListener(int family, NSInteger port)
{
    int descriptor = socket(family, SOCK_STREAM, 0);
    if (descriptor < 0) return -1;
    int reuse = 1;
    setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    int noSigPipe = 1;
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));

    int result = -1;
    if (family == AF_INET) {
        struct sockaddr_in address = {0};
        address.sin_family = AF_INET;
        address.sin_port = htons((uint16_t)port);
        address.sin_addr.s_addr = htonl(INADDR_ANY);
        result = bind(descriptor, (struct sockaddr *)&address, sizeof(address));
    } else if (family == AF_INET6) {
        int off = 0;
        setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof(off));
        struct sockaddr_in6 address = {0};
        address.sin6_family = AF_INET6;
        address.sin6_port = htons((uint16_t)port);
        address.sin6_addr = in6addr_any;
        result = bind(descriptor, (struct sockaddr *)&address, sizeof(address));
    }
    if (result != 0 || listen(descriptor, 32) != 0) {
        close(descriptor);
        return -1;
    }
    return descriptor;
}

#pragma mark - Keep-alive / Bonjour

static void WQStartKeepAlive(void)
{
    if (!gBackgroundTaskActive) {
        gBackgroundTask = [UIApplication.sharedApplication
            beginBackgroundTaskWithName:@"WQWebDAV"
            expirationHandler:^{
                if (gBackgroundTaskActive) {
                    [UIApplication.sharedApplication endBackgroundTask:gBackgroundTask];
                    gBackgroundTaskActive = NO;
                }
            }];
        gBackgroundTaskActive = gBackgroundTask != UIBackgroundTaskInvalid;
    }

    id keepAliveValue = [NSUserDefaults.standardUserDefaults objectForKey:@"WQWebDAVKeepAlive"];
    if (keepAliveValue && ![keepAliveValue boolValue]) return;
    if (gSilentPlayer) return;

    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error];
    if (error) {
        NSLog(@"[WQWebDAV] audio session category failed: %@",
              error.localizedDescription);
        return;
    }
    [session setActive:YES error:&error];
    if (error) {
        NSLog(@"[WQWebDAV] audio session activation failed: %@",
              error.localizedDescription);
        return;
    }

    // One second of 8 kHz/16-bit silence, looped. The audio background mode is
    // already declared by Filza, so the process is not suspended while the
    // WebDAV server is enabled.
    const uint32_t sampleRate = 8000;
    const uint32_t dataSize = sampleRate * 2;
    NSMutableData *wav = [NSMutableData data];
    [wav appendBytes:"RIFF" length:4];
    uint32_t riffSize = 36 + dataSize;
    [wav appendBytes:&riffSize length:4];
    [wav appendBytes:"WAVEfmt " length:8];
    uint32_t fmtSize = 16;
    [wav appendBytes:&fmtSize length:4];
    uint16_t format = 1, channels = 1, blockAlign = 2, bits = 16;
    uint32_t byteRate = sampleRate * blockAlign;
    [wav appendBytes:&format length:2];
    [wav appendBytes:&channels length:2];
    [wav appendBytes:&sampleRate length:4];
    [wav appendBytes:&byteRate length:4];
    [wav appendBytes:&blockAlign length:2];
    [wav appendBytes:&bits length:2];
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataSize length:4];
    [wav appendData:[NSMutableData dataWithLength:dataSize]];

    gSilentPlayer = [[AVAudioPlayer alloc] initWithData:wav error:&error];
    if (!gSilentPlayer) {
        NSLog(@"[WQWebDAV] silent player failed: %@", error.localizedDescription);
        return;
    }
    gSilentPlayer.numberOfLoops = -1;
    gSilentPlayer.volume = 0.01f;
    [gSilentPlayer play];
    NSLog(@"[WQWebDAV] background keep-alive active");
}

static void WQStopKeepAlive(void)
{
    [gSilentPlayer stop];
    gSilentPlayer = nil;
    [AVAudioSession.sharedInstance setActive:NO
        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    if (gBackgroundTaskActive) {
        [UIApplication.sharedApplication endBackgroundTask:gBackgroundTask];
        gBackgroundTaskActive = NO;
    }
}

static void WQStartBonjour(NSInteger port)
{
    gBonjourService = [[NSNetService alloc] initWithDomain:@"local."
        type:@"_http._tcp." name:kWQServerName port:(int)port];
    gBonjourService.includesPeerToPeer = YES;
    [gBonjourService publish];
}

#pragma mark - Lifecycle

BOOL WQWebDAVStart(NSString **error)
{
    @synchronized (gServerLock ?: (gServerLock = [NSObject new])) {
        if (WQWebDAVIsRunning()) return YES;

        NSString *root = [NSUserDefaults.standardUserDefaults stringForKey:@"WQWebDAVRoot"];
        if (!root.length) root = MCMFilzaVirtualRoot();
        root = [root stringByStandardizingPath];
        [NSFileManager.defaultManager createDirectoryAtPath:root
            withIntermediateDirectories:YES attributes:nil error:nil];
        if (![NSFileManager.defaultManager fileExistsAtPath:root]) {
            if (error) *error = @"WebDAV root does not exist";
            return NO;
        }
        gRootPath = root;
        gUsername = [NSUserDefaults.standardUserDefaults stringForKey:@"WQWebDAVUser"];
        if (!gUsername.length)
            gUsername = [NSUserDefaults.standardUserDefaults stringForKey:@"air-user"];
        gPassword = [NSUserDefaults.standardUserDefaults stringForKey:@"WQWebDAVPassword"];
        if (!gPassword.length)
            gPassword = [NSUserDefaults.standardUserDefaults stringForKey:@"air-password"];

        signal(SIGPIPE, SIG_IGN);
        gRunning = YES;
        gConnectionQueue = dispatch_queue_create(
            "com.filzaslop.worsequery.webdav", DISPATCH_QUEUE_CONCURRENT);

        NSInteger port = WQWebDAVPort();
        // Two Filza builds can coexist (public + developer). Walk a small
        // range so the second one still gets a working server instead of
        // failing on EADDRINUSE.
        BOOL bound = NO;
        for (NSInteger candidate = port; candidate < port + 10; candidate++) {
            gListen4 = WQCreateListener(AF_INET, candidate);
            gListen6 = WQCreateListener(AF_INET6, candidate);
            if (gListen4 >= 0 || gListen6 >= 0) {
                port = candidate;
                bound = YES;
                break;
            }
        }
        if (!bound) {
            gRunning = NO;
            if (error) *error = [NSString stringWithFormat:
                @"Unable to bind ports %ld-%ld (errno=%d)",
                (long)port, (long)(port + 9), errno];
            NSLog(@"[WQWebDAV] bind failed basePort=%ld errno=%d", (long)port, errno);
            return NO;
        }
        gBoundPort = port;

        pthread_t thread;
        if (gListen4 >= 0 &&
            pthread_create(&thread, NULL, WQAcceptLoop,
                           (void *)(intptr_t)gListen4) == 0)
            pthread_detach(thread);
        if (gListen6 >= 0 &&
            pthread_create(&thread, NULL, WQAcceptLoop,
                           (void *)(intptr_t)gListen6) == 0)
            pthread_detach(thread);

        WQStartBonjour(port);
        WQStartKeepAlive();
        NSLog(@"[WQWebDAV] started root=%@ url=%@ ipv4=%d ipv6=%d",
              root, WQWebDAVURL(), gListen4 >= 0, gListen6 >= 0);
        return YES;
    }
}

void WQWebDAVStop(void)
{
    @synchronized (gServerLock ?: (gServerLock = [NSObject new])) {
        if (!gRunning && gListen4 < 0 && gListen6 < 0) return;
        gRunning = NO;
        if (gListen4 >= 0) { shutdown(gListen4, SHUT_RDWR); close(gListen4); gListen4 = -1; }
        if (gListen6 >= 0) { shutdown(gListen6, SHUT_RDWR); close(gListen6); gListen6 = -1; }
        [gBonjourService stop];
        gBonjourService = nil;
        WQStopKeepAlive();
        gRootPath = nil;
        NSLog(@"[WQWebDAV] stopped");
    }
}
