// main.m - iOS Entry Point for LabelleGame
//
// This minimal Objective-C file allows Xcode to compile source code,
// which satisfies iOS code signing requirements.
// The actual game logic is in the Zig static library (libBakeryGame.a).

#import <Foundation/Foundation.h>

// Declare the Zig entry point
extern void labelle_ios_main(void);

int main(int argc, char * argv[]) {
    @autoreleasepool {
        // Call into the Zig static library
        // This sets up sokol_app which handles UIApplication lifecycle
        labelle_ios_main();
    }
    return 0;
}
