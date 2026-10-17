#!/usr/bin/env python3
"""Turn a Swift Playgrounds .swiftpm into an unsigned iOS app Xcode project."""

import hashlib
import pathlib
import re
import shutil
import sys


def uid(seed: str) -> str:
    return hashlib.sha1(seed.encode()).hexdigest()[:24].upper()


def pbx_quote(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_./]+", value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def read_package(package_swift: pathlib.Path) -> tuple[str, str, str]:
    text = package_swift.read_text(errors="ignore") if package_swift.exists() else ""
    name_match = re.search(r"\bname:\s*\"([^\"]+)\"", text)
    bundle_match = re.search(r"\bbundleIdentifier:\s*\"([^\"]+)\"", text)
    ios_match = re.search(r"\.iOS\(\s*\"([0-9.]+)\"\s*\)", text) or re.search(
        r"\.iOS\(\s*\.v([0-9]+)\s*\)", text
    )
    name = name_match.group(1) if name_match else package_swift.parent.name.removesuffix(".swiftpm")
    if not name:
        name = "App"
    bundle_id = bundle_match.group(1) if bundle_match else "com.swiftcontainer." + re.sub(r"[^A-Za-z0-9]+", "", name)
    if ios_match:
        deployment = ios_match.group(1) if "." in ios_match.group(1) else f"{ios_match.group(1)}.0"
    else:
        deployment = "16.0"
    return name, bundle_id, deployment


SKIP_DIRS = {".git", ".github", ".build", "BuildSupport", "SwiftContainerBuild", "build"}
SKIP_FILES = {"Package.swift", "Package.resolved", ".DS_Store", "source.json"}


def collect(source: pathlib.Path) -> list[pathlib.Path]:
    entries: list[pathlib.Path] = []

    def walk(directory: pathlib.Path) -> None:
        for path in sorted(directory.iterdir(), key=lambda item: item.name):
            if path.name in SKIP_FILES or path.name.startswith("."):
                continue
            if path.is_dir():
                if path.name in SKIP_DIRS:
                    continue
                if path.suffix == ".xcassets":
                    entries.append(path)
                    continue
                walk(path)
                continue
            if path.suffix == ".md":
                continue
            entries.append(path)

    walk(source)
    return entries


def file_type(path: pathlib.Path) -> str:
    if path.suffix == ".swift":
        return "sourcecode.swift"
    if path.suffix == ".xcassets":
        return "folder.assetcatalog"
    if path.suffix == ".png":
        return "image.png"
    if path.suffix in {".jpg", ".jpeg"}:
        return "image.jpeg"
    if path.suffix == ".pdf":
        return "image.pdf"
    if path.suffix == ".json":
        return "text.json"
    if path.suffix == ".strings":
        return "text.plist.strings"
    if path.suffix == ".storyboard":
        return "file.storyboard"
    return "file"


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: generate_xcodeproj.py <swiftpm-dir> <output-dir>", file=sys.stderr)
        return 2
    source = pathlib.Path(sys.argv[1]).resolve()
    output = pathlib.Path(sys.argv[2]).resolve()
    package_swift = source / "Package.swift"
    display_name, bundle_id, deployment = read_package(package_swift)
    files = collect(source)
    swift_files = [path for path in files if path.suffix == ".swift"]
    if not swift_files:
        print("No Swift sources found in the Playgrounds package.", file=sys.stderr)
        return 1

    if output.exists():
        shutil.rmtree(output)
    app_dir = output / "App"
    app_dir.mkdir(parents=True)
    for path in files:
        relative = path.relative_to(source)
        destination = app_dir / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if path.is_dir():
            shutil.copytree(path, destination)
        else:
            shutil.copy2(path, destination)

    project_dir = output / "App.xcodeproj"
    project_dir.mkdir()
    scheme_dir = project_dir / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True)

    target_id = uid("target")
    project_id = uid("project")
    sources_phase = uid("sources")
    resources_phase = uid("resources")
    target_config_list = uid("target-configs")
    project_config_list = uid("project-configs")
    target_debug = uid("target-debug")
    target_release = uid("target-release")
    project_debug = uid("project-debug")
    project_release = uid("project-release")
    product_ref = uid("product")

    build_files = []
    file_refs = []
    source_refs = []
    resource_refs = []
    resource_suffixes = {".xcassets", ".png", ".jpg", ".jpeg", ".pdf", ".json", ".strings", ".storyboard", ".mp3", ".wav", ".ttf", ".otf"}

    for path in files:
        relative = path.relative_to(source).as_posix()
        file_id = uid("file:" + relative)
        build_id = uid("build:" + relative)
        file_refs.append(
            f"\t\t{file_id} /* {relative} */ = {{isa = PBXFileReference; lastKnownFileType = {file_type(path)}; path = {pbx_quote(relative)}; sourceTree = \"<group>\"; }};"
        )
        if path.suffix == ".swift":
            build_files.append(
                f"\t\t{build_id} /* {relative} */ = {{isa = PBXBuildFile; fileRef = {file_id}; }};"
            )
            source_refs.append(f"\t\t\t\t{build_id} /* {relative} */,")
        elif path.suffix in resource_suffixes or path.name.endswith(".xcassets"):
            build_files.append(
                f"\t\t{build_id} /* {relative} */ = {{isa = PBXBuildFile; fileRef = {file_id}; }};"
            )
            resource_refs.append(f"\t\t\t\t{build_id} /* {relative} */,")

    group_children = "\n".join(f"\t\t\t\t{line.strip().split()[0]}," for line in file_refs)
    build_file_block = "\n".join(build_files)
    file_ref_block = "\n".join(file_refs)
    source_ref_block = "\n".join(source_refs)
    resource_ref_block = "\n".join(resource_refs)

    common_target_settings = f"""
				CODE_SIGNING_ALLOWED = NO;
				CODE_SIGNING_REQUIRED = NO;
				CODE_SIGN_IDENTITY = "";
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = {pbx_quote(display_name)};
				INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown";
				IPHONEOS_DEPLOYMENT_TARGET = {deployment};
				LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = {pbx_quote(bundle_id)};
				PRODUCT_NAME = App;
				SDKROOT = iphoneos;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
"""

    pbxproj = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{build_file_block}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		{product_ref} /* App.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = App.app; sourceTree = BUILT_PRODUCTS_DIR; }};
{file_ref_block}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{uid("frameworks")} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{uid("group-root")} = {{
			isa = PBXGroup;
			children = (
				{uid("group-app")} /* App */,
				{product_ref} /* App.app */,
			);
			sourceTree = "<group>";
		}};
		{uid("group-app")} /* App */ = {{
			isa = PBXGroup;
			children = (
{group_children}
			);
			path = App;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{target_id} /* App */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {target_config_list};
			buildPhases = (
				{sources_phase},
				{uid("frameworks")},
				{resources_phase},
			);
			buildRules = (
			);
			dependencies = (
			);
			name = App;
			productName = App;
			productReference = {product_ref};
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{project_id} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastUpgradeCheck = 1600;
			}};
			buildConfigurationList = {project_config_list};
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {uid("group-root")};
			productRefGroup = {uid("group-root")};
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{target_id} /* App */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{resources_phase} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{resource_ref_block}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{sources_phase} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{source_ref_block}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{project_debug} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_BITCODE = NO;
				IPHONEOS_DEPLOYMENT_TARGET = {deployment};
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = iphoneos;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			}};
			name = Debug;
		}};
		{project_release} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_BITCODE = NO;
				IPHONEOS_DEPLOYMENT_TARGET = {deployment};
				SDKROOT = iphoneos;
				SWIFT_COMPILATION_MODE = wholemodule;
				VALIDATE_PRODUCT = YES;
			}};
			name = Release;
		}};
		{target_debug} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{common_target_settings}			}};
			name = Debug;
		}};
		{target_release} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{common_target_settings}			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{project_config_list} /* Build configuration list for PBXProject */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{project_debug} /* Debug */,
				{project_release} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{target_config_list} /* Build configuration list for PBXNativeTarget */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{target_debug} /* Debug */,
				{target_release} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {project_id};
}}
"""
    (project_dir / "project.pbxproj").write_text(pbxproj)
    scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference
               BuildableIdentifier="primary"
               BlueprintIdentifier="{target_id}"
               BuildableName="App.app"
               BlueprintName="App"
               ReferencedContainer="container:App.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES" />
</Scheme>
"""
    (scheme_dir / "App.xcscheme").write_text(scheme)
    print(f"display_name={display_name}")
    print(f"bundle_id={bundle_id}")
    print(f"deployment={deployment}")
    print(f"swift_files={len(swift_files)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
