#!/usr/bin/env python3
"""Generate a dependency-free Xcode app project backed by the local core package."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parent.parent
project = root / 'YukinoTools.xcodeproj'
project.mkdir(exist_ok=True)
objects = []

def uid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

def quote(value):
    return json.dumps(str(value))

def obj(name, isa, fields):
    key = uid(name)
    objects.append(f'\t\t{key} /* {name} */ = {{\n\t\t\tisa = {isa};\n{fields}\n\t\t}};')
    return key

def array(values):
    return '(' + ', '.join(values) + ')'

sources = sorted((root / 'Sources/YukinoTools').rglob('*.swift'))
groups = {}
build_files = []
for source in sources:
    path = source.relative_to(root)
    ref = obj(str(path), 'PBXFileReference', f'\t\t\tlastKnownFileType = sourcecode.swift;\n\t\t\tpath = {quote(path)};\n\t\t\tsourceTree = SOURCE_ROOT;')
    build = obj(str(path) + ' in Sources', 'PBXBuildFile', f'\t\t\tfileRef = {ref};')
    build_files.append(build)
    groups.setdefault(source.parent.name, []).append(ref)
source_groups = [obj(name, 'PBXGroup', f'\t\t\tchildren = {array(refs)};\n\t\t\tname = {name};\n\t\t\tsourceTree = "<group>";') for name, refs in groups.items()]
icon = obj('AppIcon.icns', 'PBXFileReference', '\t\t\tlastKnownFileType = image.icns;\n\t\t\tpath = Resources/AppIcon.icns;\n\t\t\tsourceTree = SOURCE_ROOT;')
icon_build = obj('AppIcon in Resources', 'PBXBuildFile', f'\t\t\tfileRef = {icon};')
info = obj('Info.plist', 'PBXFileReference', '\t\t\tlastKnownFileType = text.plist.xml;\n\t\t\tpath = Resources/Info.plist;\n\t\t\tsourceTree = SOURCE_ROOT;')
resources_group = obj('Resources', 'PBXGroup', f'\t\t\tchildren = {array([icon, info])};\n\t\t\tname = Resources;\n\t\t\tsourceTree = "<group>";')
product = obj('Yukino Tools.app', 'PBXFileReference', '\t\t\texplicitFileType = wrapper.application;\n\t\t\tincludeInIndex = 0;\n\t\t\tpath = "Yukino Tools.app";\n\t\t\tsourceTree = BUILT_PRODUCTS_DIR;')
products = obj('Products', 'PBXGroup', f'\t\t\tchildren = ({product});\n\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";')
main_group = obj('Main group', 'PBXGroup', f'\t\t\tchildren = {array(source_groups + [resources_group, products])};\n\t\t\tsourceTree = "<group>";')
package = obj('Local Yukino core package', 'XCLocalSwiftPackageReference', '\t\t\trelativePath = .;')
core = obj('YukinoCore', 'XCSwiftPackageProductDependency', f'\t\t\tpackage = {package};\n\t\t\tproductName = YukinoCore;')
core_build = obj('YukinoCore in Frameworks', 'PBXBuildFile', f'\t\t\tproductRef = {core};')
phases = []
for name, isa, files in [('Sources', 'PBXSourcesBuildPhase', build_files), ('Frameworks', 'PBXFrameworksBuildPhase', [core_build]), ('Bundle resources', 'PBXResourcesBuildPhase', [icon_build])]:
    phases.append(obj(name, isa, f'\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = {array(files)};\n\t\t\trunOnlyForDeploymentPostprocessing = 0;'))

project_configs = []
app_configs = []
for config in ['Debug', 'Release']:
    settings = {'MACOSX_DEPLOYMENT_TARGET': '14.0', 'SDKROOT': 'macosx', 'SWIFT_VERSION': '5.0', 'CLANG_ENABLE_MODULES': 'YES', 'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if config == 'Debug' else '-O', 'DEBUG_INFORMATION_FORMAT': 'dwarf' if config == 'Debug' else 'dwarf-with-dsym'}
    if config == 'Debug':
        settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
        settings['ENABLE_TESTABILITY'] = 'YES'
    fields = '\n'.join(f'\t\t\t\t{k} = {quote(v)};' for k, v in settings.items())
    project_configs.append(obj(f'Project {config}', 'XCBuildConfiguration', f'\t\t\tbuildSettings = {{\n{fields}\n\t\t\t}};\n\t\t\tname = {config};'))
    app_settings = {'PRODUCT_NAME': 'Yukino Tools', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.yukino.tools', 'EXECUTABLE_NAME': 'YukinoTools', 'INFOPLIST_FILE': 'Resources/Info.plist', 'GENERATE_INFOPLIST_FILE': 'NO', 'CODE_SIGN_STYLE': 'Manual', 'CODE_SIGN_IDENTITY': '-', 'ENABLE_APP_SANDBOX': 'NO', 'ENABLE_HARDENED_RUNTIME': 'YES', 'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/../Frameworks', 'COMBINE_HIDPI_IMAGES': 'YES'}
    fields = '\n'.join(f'\t\t\t\t{k} = {quote(v)};' for k, v in app_settings.items())
    app_configs.append(obj(f'App {config}', 'XCBuildConfiguration', f'\t\t\tbuildSettings = {{\n{fields}\n\t\t\t}};\n\t\t\tname = {config};'))

project_list = obj('Project configurations', 'XCConfigurationList', f'\t\t\tbuildConfigurations = {array(project_configs)};\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;')
app_list = obj('App configurations', 'XCConfigurationList', f'\t\t\tbuildConfigurations = {array(app_configs)};\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;')
target = obj('YukinoToolsApp', 'PBXNativeTarget', f'\t\t\tbuildConfigurationList = {app_list};\n\t\t\tbuildPhases = {array(phases)};\n\t\t\tbuildRules = ();\n\t\t\tdependencies = ();\n\t\t\tname = YukinoToolsApp;\n\t\t\tpackageProductDependencies = ({core});\n\t\t\tproductName = "Yukino Tools";\n\t\t\tproductReference = {product};\n\t\t\tproductType = "com.apple.product-type.application";')
project_id = obj('Project', 'PBXProject', f'\t\t\tattributes = {{ LastUpgradeCheck = 1500; }};\n\t\t\tbuildConfigurationList = {project_list};\n\t\t\tcompatibilityVersion = "Xcode 14.0";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (en, Base);\n\t\t\tmainGroup = {main_group};\n\t\t\tpackageReferences = ({package});\n\t\t\tproductRefGroup = {products};\n\t\t\tprojectDirPath = "";\n\t\t\tprojectRoot = "";\n\t\t\ttargets = ({target});')
content = '// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n' + '\n'.join(objects) + '\n\t};\n\trootObject = ' + project_id + ';\n}\n'
(project / 'project.pbxproj').write_text(content)
scheme_dir = project / 'xcshareddata/xcschemes'
scheme_dir.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Yukino Tools.app" BlueprintName="YukinoToolsApp" ReferencedContainer="container:YukinoTools.xcodeproj"/>'
(scheme_dir / 'YukinoTools.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1500" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(project)
