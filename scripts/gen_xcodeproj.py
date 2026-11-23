#!/usr/bin/env python3
"""Generuje ios/QuizVerse.xcodeproj (format Xcode 16+, foldery synchronizowane).

Pliki źródłowe nie są wymieniane w projekcie – Xcode sam dołącza wszystko z folderów
ios/QuizVerse (aplikacja) i ios/QuizVerseTests (testy). Uruchom ponownie tylko przy zmianie
ustawień celu: python3 scripts/gen_xcodeproj.py
"""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "ios"
PROJ = ROOT / "QuizVerse.xcodeproj"


def oid(name: str) -> str:
    return hashlib.md5(("quizverse:" + name).encode()).hexdigest()[:24].upper()


I = {k: oid(k) for k in [
    "project", "main", "products", "config_group", "support_group", "app_group", "test_group",
    "app_product", "test_product", "base_xcconfig", "info_plist",
    "app_target", "test_target", "app_sources", "app_frameworks", "app_resources",
    "test_sources", "test_frameworks", "test_resources", "proxy", "dependency",
    "proj_cfgs", "proj_debug", "proj_release", "app_cfgs", "app_debug", "app_release",
    "test_cfgs", "test_debug", "test_release",
]}


def settings(d: dict) -> str:
    lines = []
    for k in sorted(d):
        v = d[k]
        if isinstance(v, list):
            inner = "".join(f'\t\t\t\t\t"{x}",\n' for x in v)
            lines.append(f"\t\t\t\t{k} = (\n{inner}\t\t\t\t);")
        else:
            s = str(v)
            if s == "" or any(c in s for c in ' $()/"-+=@,') or not s.replace("_", "").replace(".", "").isalnum():
                s = '"' + s.replace('"', '\\"') + '"'
            lines.append(f"\t\t\t\t{k} = {s};")
    return "\n".join(lines)


COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_ENABLE_OBJC_WEAK": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "MTL_FAST_MATH": "YES",
    "SDKROOT": "iphoneos",
    "SWIFT_VERSION": "5.0",
}
PROJ_DEBUG = {**COMMON,
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_DYNAMIC_NO_PIC": "NO",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
}
PROJ_RELEASE = {**COMMON,
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS": "NO",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "VALIDATE_PRODUCT": "YES",
}
APP = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_FILE": "Support/Info.plist",
    "INFOPLIST_KEY_CFBundleDisplayName": "QUIZVERSE",
    "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.education",
    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
    "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
    "INFOPLIST_KEY_UIStatusBarStyle": "UIStatusBarStyleLightContent",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations": "UIInterfaceOrientationPortrait",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
    "MARKETING_VERSION": "1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": "$(QV_BUNDLE_ID)",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    "SUPPORTS_MACCATALYST": "NO",
    "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "TARGETED_DEVICE_FAMILY": "1",
}
TEST = {
    "BUNDLE_LOADER": "$(TEST_HOST)",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "GENERATE_INFOPLIST_FILE": "YES",
    "MARKETING_VERSION": "1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": "$(QV_BUNDLE_ID).tests",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SWIFT_EMIT_LOC_STRINGS": "NO",
    "TARGETED_DEVICE_FAMILY": "1",
    "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/QuizVerse.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/QuizVerse",
}


def cfg(key, name, d, base=False):
    base_line = f"\t\t\tbaseConfigurationReference = {I['base_xcconfig']} /* Base.xcconfig */;\n" if base else ""
    return (f"\t\t{I[key]} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n{base_line}"
            f"\t\t\tbuildSettings = {{\n{settings(d)}\n\t\t\t}};\n\t\t\tname = {name};\n\t\t}};\n")


def phase(key, isa):
    return (f"\t\t{I[key]} = {{\n\t\t\tisa = {isa};\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n"
            f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")


def cfglist(key, debug, release, comment):
    return (f"\t\t{I[key]} /* Build configuration list for {comment} */ = {{\n\t\t\tisa = XCConfigurationList;\n"
            f"\t\t\tbuildConfigurations = (\n\t\t\t\t{I[debug]} /* Debug */,\n\t\t\t\t{I[release]} /* Release */,\n\t\t\t);\n"
            f"\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n")


pbx = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{

/* Begin PBXContainerItemProxy section */
		{I['proxy']} /* PBXContainerItemProxy */ = {{
			isa = PBXContainerItemProxy;
			containerPortal = {I['project']} /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = {I['app_target']};
			remoteInfo = QuizVerse;
		}};
/* End PBXContainerItemProxy section */

/* Begin PBXFileReference section */
		{I['app_product']} /* QuizVerse.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = QuizVerse.app; sourceTree = BUILT_PRODUCTS_DIR; }};
		{I['test_product']} /* QuizVerseTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = QuizVerseTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};
		{I['base_xcconfig']} /* Base.xcconfig */ = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Base.xcconfig; sourceTree = "<group>"; }};
		{I['info_plist']} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		{I['app_group']} /* QuizVerse */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = QuizVerse; sourceTree = "<group>"; }};
		{I['test_group']} /* QuizVerseTests */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = QuizVerseTests; sourceTree = "<group>"; }};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
{phase('app_frameworks', 'PBXFrameworksBuildPhase')}{phase('test_frameworks', 'PBXFrameworksBuildPhase')}/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{I['main']} = {{
			isa = PBXGroup;
			children = (
				{I['app_group']} /* QuizVerse */,
				{I['test_group']} /* QuizVerseTests */,
				{I['config_group']} /* Config */,
				{I['support_group']} /* Support */,
				{I['products']} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{I['products']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{I['app_product']} /* QuizVerse.app */,
				{I['test_product']} /* QuizVerseTests.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
		{I['config_group']} /* Config */ = {{
			isa = PBXGroup;
			children = (
				{I['base_xcconfig']} /* Base.xcconfig */,
			);
			path = Config;
			sourceTree = "<group>";
		}};
		{I['support_group']} /* Support */ = {{
			isa = PBXGroup;
			children = (
				{I['info_plist']} /* Info.plist */,
			);
			path = Support;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{I['app_target']} /* QuizVerse */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {I['app_cfgs']} /* Build configuration list for PBXNativeTarget "QuizVerse" */;
			buildPhases = (
				{I['app_sources']} /* Sources */,
				{I['app_frameworks']} /* Frameworks */,
				{I['app_resources']} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{I['app_group']} /* QuizVerse */,
			);
			name = QuizVerse;
			packageProductDependencies = (
			);
			productName = QuizVerse;
			productReference = {I['app_product']} /* QuizVerse.app */;
			productType = "com.apple.product-type.application";
		}};
		{I['test_target']} /* QuizVerseTests */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {I['test_cfgs']} /* Build configuration list for PBXNativeTarget "QuizVerseTests" */;
			buildPhases = (
				{I['test_sources']} /* Sources */,
				{I['test_frameworks']} /* Frameworks */,
				{I['test_resources']} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
				{I['dependency']} /* PBXTargetDependency */,
			);
			fileSystemSynchronizedGroups = (
				{I['test_group']} /* QuizVerseTests */,
			);
			name = QuizVerseTests;
			packageProductDependencies = (
			);
			productName = QuizVerseTests;
			productReference = {I['test_product']} /* QuizVerseTests.xctest */;
			productType = "com.apple.product-type.bundle.unit-test";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{I['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {{
					{I['app_target']} = {{
						CreatedOnToolsVersion = 16.0;
					}};
					{I['test_target']} = {{
						CreatedOnToolsVersion = 16.0;
						TestTargetID = {I['app_target']};
					}};
				}};
			}};
			buildConfigurationList = {I['proj_cfgs']} /* Build configuration list for PBXProject "QuizVerse" */;
			developmentRegion = pl;
			hasScannedForEncodings = 0;
			knownRegions = (
				pl,
				en,
				Base,
			);
			mainGroup = {I['main']};
			minimizedProjectReferenceProxies = 1;
			preferredProjectObjectVersion = 77;
			productRefGroup = {I['products']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{I['app_target']} /* QuizVerse */,
				{I['test_target']} /* QuizVerseTests */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
{phase('app_resources', 'PBXResourcesBuildPhase')}{phase('test_resources', 'PBXResourcesBuildPhase')}/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
{phase('app_sources', 'PBXSourcesBuildPhase')}{phase('test_sources', 'PBXSourcesBuildPhase')}/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
		{I['dependency']} /* PBXTargetDependency */ = {{
			isa = PBXTargetDependency;
			target = {I['app_target']} /* QuizVerse */;
			targetProxy = {I['proxy']} /* PBXContainerItemProxy */;
		}};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
{cfg('proj_debug', 'Debug', PROJ_DEBUG, base=True)}{cfg('proj_release', 'Release', PROJ_RELEASE, base=True)}{cfg('app_debug', 'Debug', APP)}{cfg('app_release', 'Release', APP)}{cfg('test_debug', 'Debug', TEST)}{cfg('test_release', 'Release', TEST)}/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
{cfglist('proj_cfgs', 'proj_debug', 'proj_release', 'PBXProject "QuizVerse"')}{cfglist('app_cfgs', 'app_debug', 'app_release', 'PBXNativeTarget "QuizVerse"')}{cfglist('test_cfgs', 'test_debug', 'test_release', 'PBXNativeTarget "QuizVerseTests"')}/* End XCConfigurationList section */
	}};
	rootObject = {I['project']} /* Project object */;
}}
"""

SCHEME = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{I['app_target']}" BuildableName = "QuizVerse.app" BlueprintName = "QuizVerse" ReferencedContainer = "container:QuizVerse.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES" shouldAutocreateTestPlan = "YES">
      <Testables>
         <TestableReference skipped = "NO" parallelizable = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{I['test_target']}" BuildableName = "QuizVerseTests.xctest" BlueprintName = "QuizVerseTests" ReferencedContainer = "container:QuizVerse.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{I['app_target']}" BuildableName = "QuizVerse.app" BlueprintName = "QuizVerse" ReferencedContainer = "container:QuizVerse.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{I['app_target']}" BuildableName = "QuizVerse.app" BlueprintName = "QuizVerse" ReferencedContainer = "container:QuizVerse.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""

PROJ.mkdir(exist_ok=True)
(PROJ / "project.pbxproj").write_text(pbx)
schemes = PROJ / "xcshareddata" / "xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
(schemes / "QuizVerse.xcscheme").write_text(SCHEME)
ws = PROJ / "project.xcworkspace"
ws.mkdir(exist_ok=True)
(ws / "contents.xcworkspacedata").write_text(
    '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace\n   version = "1.0">\n   <FileRef\n      location = "self:">\n   </FileRef>\n</Workspace>\n')
print("OK:", PROJ)
