#import <Foundation/Foundation.h>

BOOL ValidRelayCode(NSString *code);
NSString *RelayRequest(NSString *code, BOOL switchInput, NSString **error);
