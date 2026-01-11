#!/bin/bash
# ============================================================================
# Xcode Project Generator for Bakery Game iOS
# ============================================================================
# This script creates a minimal Xcode project that wraps the Zig-built binary.
#
# Usage:
#   ./generate_xcode.sh [options]
#
# Options:
#   --app-name NAME       App display name (default: Bakery Game)
#   --bundle-id ID        Bundle identifier (default: com.labelle.bakery)
#   --team-id ID          Apple Developer Team ID (required for signing)
#   --output DIR          Output directory (default: ./xcode)
#
# Prerequisites:
#   - Run 'zig build ios' first to build the binary
#   - Xcode must be installed for code signing
# ============================================================================

set -e

# Default values
APP_NAME="Bakery Game"
BUNDLE_ID="com.labelle.bakery"
TEAM_ID=""
OUTPUT_DIR="./xcode"
BINARY_PATH="./zig-out/bin/BakeryGame"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --app-name)
            APP_NAME="$2"
            shift 2
            ;;
        --bundle-id)
            BUNDLE_ID="$2"
            shift 2
            ;;
        --team-id)
            TEAM_ID="$2"
            shift 2
            ;;
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Sanitize app name for use in identifiers (remove spaces)
APP_NAME_SAFE=$(echo "$APP_NAME" | tr -d ' ')

# Check if binary exists
if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: Binary not found at $BINARY_PATH"
    echo "Run 'zig build ios' first to build the binary."
    exit 1
fi

echo "Generating Xcode project..."
echo "  App Name: $APP_NAME"
echo "  Bundle ID: $BUNDLE_ID"
echo "  Output: $OUTPUT_DIR"

# Create directory structure
XCODEPROJ="$OUTPUT_DIR/${APP_NAME_SAFE}.xcodeproj"
APP_DIR="$OUTPUT_DIR/${APP_NAME_SAFE}"

mkdir -p "$XCODEPROJ"
mkdir -p "$APP_DIR"
mkdir -p "$APP_DIR/Assets.xcassets/AppIcon.appiconset"

# Copy binary
cp "$BINARY_PATH" "$APP_DIR/${APP_NAME_SAFE}"

# Copy templates
cp ./templates/Info.plist "$APP_DIR/"
cp ./templates/LaunchScreen.storyboard "$APP_DIR/"

# Create AppIcon Contents.json (placeholder - no icons yet)
cat > "$APP_DIR/Assets.xcassets/AppIcon.appiconset/Contents.json" << 'EOF'
{
  "images" : [
    {
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

# Create Assets.xcassets Contents.json
cat > "$APP_DIR/Assets.xcassets/Contents.json" << 'EOF'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

# Copy game resources (atlases, project.labelle, etc.)
if [ -d "../resources" ]; then
    cp -r ../resources "$APP_DIR/"
fi
if [ -f "../project.labelle" ]; then
    cp ../project.labelle "$APP_DIR/"
fi

# Generate UUIDs for Xcode project
UUID_PROJECT=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_ROOT_GROUP=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_SOURCES_GROUP=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_RESOURCES_GROUP=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_PRODUCTS_GROUP=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_TARGET=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_BUILD_CONFIG_DEBUG=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_BUILD_CONFIG_RELEASE=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_BUILD_CONFIG_LIST_PROJECT=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_BUILD_CONFIG_LIST_TARGET=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_BUILD_CONFIG_TARGET_DEBUG=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_BUILD_CONFIG_TARGET_RELEASE=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_COPY_FILES_PHASE=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_RESOURCES_PHASE=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_PRODUCT_REF=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_BINARY_REF=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_INFO_PLIST_REF=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_LAUNCH_STORYBOARD_REF=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_ASSETS_REF=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_RESOURCES_DIR_REF=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_PROJECT_LABELLE_REF=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_BINARY_BUILD_REF=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_LAUNCH_BUILD_REF=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_ASSETS_BUILD_REF=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_RESOURCES_BUILD_REF=$(uuidgen | tr -d '-' | cut -c1-24)
UUID_PROJECT_LABELLE_BUILD_REF=$(uuidgen | tr -d '-' | cut -c1-24)

# Code signing disabled by default for simulator support without developer account
# For device deployment, configure signing in Xcode manually

# Generate project.pbxproj
cat > "$XCODEPROJ/project.pbxproj" << EOF
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 56;
	objects = {

/* Begin PBXBuildFile section */
		${UUID_BINARY_BUILD_REF} /* ${APP_NAME_SAFE} in CopyFiles */ = {isa = PBXBuildFile; fileRef = ${UUID_BINARY_REF} /* ${APP_NAME_SAFE} */; };
		${UUID_LAUNCH_BUILD_REF} /* LaunchScreen.storyboard in Resources */ = {isa = PBXBuildFile; fileRef = ${UUID_LAUNCH_STORYBOARD_REF} /* LaunchScreen.storyboard */; };
		${UUID_ASSETS_BUILD_REF} /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = ${UUID_ASSETS_REF} /* Assets.xcassets */; };
		${UUID_RESOURCES_BUILD_REF} /* resources in Resources */ = {isa = PBXBuildFile; fileRef = ${UUID_RESOURCES_DIR_REF} /* resources */; };
		${UUID_PROJECT_LABELLE_BUILD_REF} /* project.labelle in Resources */ = {isa = PBXBuildFile; fileRef = ${UUID_PROJECT_LABELLE_REF} /* project.labelle */; };
/* End PBXBuildFile section */

/* Begin PBXCopyFilesBuildPhase section */
		${UUID_COPY_FILES_PHASE} /* CopyFiles */ = {
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			dstPath = "";
			dstSubfolderSpec = 6;
			files = (
				${UUID_BINARY_BUILD_REF} /* ${APP_NAME_SAFE} in CopyFiles */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXCopyFilesBuildPhase section */

/* Begin PBXFileReference section */
		${UUID_PRODUCT_REF} /* ${APP_NAME_SAFE}.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "${APP_NAME_SAFE}.app"; sourceTree = BUILT_PRODUCTS_DIR; };
		${UUID_BINARY_REF} /* ${APP_NAME_SAFE} */ = {isa = PBXFileReference; lastKnownFileType = "compiled.mach-o.executable"; path = "${APP_NAME_SAFE}"; sourceTree = "<group>"; };
		${UUID_INFO_PLIST_REF} /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
		${UUID_LAUNCH_STORYBOARD_REF} /* LaunchScreen.storyboard */ = {isa = PBXFileReference; lastKnownFileType = file.storyboard; path = LaunchScreen.storyboard; sourceTree = "<group>"; };
		${UUID_ASSETS_REF} /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; };
		${UUID_RESOURCES_DIR_REF} /* resources */ = {isa = PBXFileReference; lastKnownFileType = folder; path = resources; sourceTree = "<group>"; };
		${UUID_PROJECT_LABELLE_REF} /* project.labelle */ = {isa = PBXFileReference; lastKnownFileType = text; path = project.labelle; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXGroup section */
		${UUID_ROOT_GROUP} = {
			isa = PBXGroup;
			children = (
				${UUID_SOURCES_GROUP} /* ${APP_NAME_SAFE} */,
				${UUID_PRODUCTS_GROUP} /* Products */,
			);
			sourceTree = "<group>";
		};
		${UUID_SOURCES_GROUP} /* ${APP_NAME_SAFE} */ = {
			isa = PBXGroup;
			children = (
				${UUID_BINARY_REF} /* ${APP_NAME_SAFE} */,
				${UUID_INFO_PLIST_REF} /* Info.plist */,
				${UUID_LAUNCH_STORYBOARD_REF} /* LaunchScreen.storyboard */,
				${UUID_ASSETS_REF} /* Assets.xcassets */,
				${UUID_RESOURCES_DIR_REF} /* resources */,
				${UUID_PROJECT_LABELLE_REF} /* project.labelle */,
			);
			path = "${APP_NAME_SAFE}";
			sourceTree = "<group>";
		};
		${UUID_PRODUCTS_GROUP} /* Products */ = {
			isa = PBXGroup;
			children = (
				${UUID_PRODUCT_REF} /* ${APP_NAME_SAFE}.app */,
			);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		${UUID_TARGET} /* ${APP_NAME_SAFE} */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = ${UUID_BUILD_CONFIG_LIST_TARGET} /* Build configuration list for PBXNativeTarget "${APP_NAME_SAFE}" */;
			buildPhases = (
				${UUID_COPY_FILES_PHASE} /* CopyFiles */,
				${UUID_RESOURCES_PHASE} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = "${APP_NAME_SAFE}";
			productName = "${APP_NAME_SAFE}";
			productReference = ${UUID_PRODUCT_REF} /* ${APP_NAME_SAFE}.app */;
			productType = "com.apple.product-type.application";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		${UUID_PROJECT} /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastUpgradeCheck = 1500;
				TargetAttributes = {
					${UUID_TARGET} = {
						CreatedOnToolsVersion = 15.0;
					};
				};
			};
			buildConfigurationList = ${UUID_BUILD_CONFIG_LIST_PROJECT} /* Build configuration list for PBXProject "${APP_NAME_SAFE}" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = ${UUID_ROOT_GROUP};
			productRefGroup = ${UUID_PRODUCTS_GROUP} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				${UUID_TARGET} /* ${APP_NAME_SAFE} */,
			);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		${UUID_RESOURCES_PHASE} /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				${UUID_LAUNCH_BUILD_REF} /* LaunchScreen.storyboard in Resources */,
				${UUID_ASSETS_BUILD_REF} /* Assets.xcassets in Resources */,
				${UUID_RESOURCES_BUILD_REF} /* resources in Resources */,
				${UUID_PROJECT_LABELLE_BUILD_REF} /* project.labelle in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		${UUID_BUILD_CONFIG_DEBUG} /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_ENABLE_OBJC_WEAK = YES;
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
				CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INFINITE_RECURSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_STRICT_PROTOTYPES = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				GCC_C_LANGUAGE_STANDARD = gnu11;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"\$(inherited)",
				);
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNDECLARED_SELECTOR = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 15.0;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				MTL_FAST_MATH = YES;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = iphoneos;
			};
			name = Debug;
		};
		${UUID_BUILD_CONFIG_RELEASE} /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_ENABLE_OBJC_WEAK = YES;
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
				CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INFINITE_RECURSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_STRICT_PROTOTYPES = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_C_LANGUAGE_STANDARD = gnu11;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNDECLARED_SELECTOR = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 15.0;
				MTL_ENABLE_DEBUG_INFO = NO;
				MTL_FAST_MATH = YES;
				SDKROOT = iphoneos;
				VALIDATE_PRODUCT = YES;
			};
			name = Release;
		};
		${UUID_BUILD_CONFIG_TARGET_DEBUG} /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_IDENTITY = "";
				CODE_SIGNING_ALLOWED = NO;
				CODE_SIGNING_REQUIRED = NO;
				INFOPLIST_FILE = "${APP_NAME_SAFE}/Info.plist";
				INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
				INFOPLIST_KEY_UILaunchStoryboardName = LaunchScreen;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				LD_RUNPATH_SEARCH_PATHS = (
					"\$(inherited)",
					"@executable_path/Frameworks",
				);
				PRODUCT_BUNDLE_IDENTIFIER = "${BUNDLE_ID}";
				PRODUCT_NAME = "\$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				TARGETED_DEVICE_FAMILY = "1,2";
			};
			name = Debug;
		};
		${UUID_BUILD_CONFIG_TARGET_RELEASE} /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_IDENTITY = "";
				CODE_SIGNING_ALLOWED = NO;
				CODE_SIGNING_REQUIRED = NO;
				INFOPLIST_FILE = "${APP_NAME_SAFE}/Info.plist";
				INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
				INFOPLIST_KEY_UILaunchStoryboardName = LaunchScreen;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				LD_RUNPATH_SEARCH_PATHS = (
					"\$(inherited)",
					"@executable_path/Frameworks",
				);
				PRODUCT_BUNDLE_IDENTIFIER = "${BUNDLE_ID}";
				PRODUCT_NAME = "\$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				TARGETED_DEVICE_FAMILY = "1,2";
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		${UUID_BUILD_CONFIG_LIST_PROJECT} /* Build configuration list for PBXProject "${APP_NAME_SAFE}" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				${UUID_BUILD_CONFIG_DEBUG} /* Debug */,
				${UUID_BUILD_CONFIG_RELEASE} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		${UUID_BUILD_CONFIG_LIST_TARGET} /* Build configuration list for PBXNativeTarget "${APP_NAME_SAFE}" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				${UUID_BUILD_CONFIG_TARGET_DEBUG} /* Debug */,
				${UUID_BUILD_CONFIG_TARGET_RELEASE} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */
	};
	rootObject = ${UUID_PROJECT} /* Project object */;
}
EOF

echo ""
echo "Xcode project generated at: $XCODEPROJ"
echo ""
echo "Next steps:"
echo "  1. Open the project: open \"$XCODEPROJ\""
echo "  2. Select your development team in Xcode (Signing & Capabilities)"
echo "  3. Add app icons to Assets.xcassets/AppIcon.appiconset/"
echo "  4. Build and run on device or simulator"
echo ""
if [ -z "$TEAM_ID" ]; then
    echo "Note: No team ID specified. You'll need to configure signing in Xcode."
fi
