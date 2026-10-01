#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
void customLog(NSString *format, ...);
void customLog2(NSString *format, ...);
// The file both loggers append to, and emptying it (for the in-app log viewer).
NSString *AYLogFilePath(void);
void AYClearLog(void);
#ifdef __cplusplus
}
#endif
