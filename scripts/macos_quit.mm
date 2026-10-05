#import <AppKit/AppKit.h>
#include <cstdlib>

int main(int argc, char** argv) {
  if (argc != 3) return 2;
  @autoreleasepool {
    NSRunningApplication* app = [NSRunningApplication runningApplicationWithProcessIdentifier:atoi(argv[1])];
    NSString* expected = [[NSString stringWithUTF8String:argv[2]] stringByResolvingSymlinksInPath];
    if (!app || ![[app.bundleURL.path stringByResolvingSymlinksInPath] isEqualToString:expected]) return 3;
    // Requests ordinary Quit for this exact process, rather than sending SIGTERM.
    return [app terminate] ? 0 : 1;
  }
}
