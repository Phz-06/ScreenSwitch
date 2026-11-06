#import <Foundation/Foundation.h>

BOOL ValidRelayCode(NSString *code);
NSString *RelayRequest(NSString *code, BOOL switchInput, NSString **error);
NSString *RelayRequestCommand(NSString *code, uint8_t command, NSString **error);
NSString *RelayGetUpdatedCode(void);
