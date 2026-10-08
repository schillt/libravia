#!/usr/bin/env python3
"""Deterministically generate the checked-in Xcode project; no external generator needed."""
from pathlib import Path
import hashlib
root = Path(__file__).resolve().parent.parent
objects = {}
def uid(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(name, text):
    key = uid(name); objects[key] = text; return key
def array(items): return '(' + ', '.join(items) + ',)'
def quote(value): return '"' + value.replace('"', '\\"') + '"'
files = []
for path in sorted((root/'App').rglob('*.swift')):
    rel = str(path.relative_to(root)); key = add(rel, '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = '+quote(rel)+'; sourceTree = SOURCE_ROOT;}'); files.append(key)
resources = []
for folder in ['Reader', 'Archive', 'Licenses', 'Fixtures']:
    resourcepath = 'Fixtures' if folder == 'Fixtures' else 'App/Resources/'+folder
    resources.append(add(folder, '{isa = PBXFileReference; lastKnownFileType = folder; path = "'+resourcepath+'"; sourceTree = SOURCE_ROOT;}'))
resources.append(add('PrivacyInfo', '{isa = PBXFileReference; lastKnownFileType = text.xml; path = App/Resources/PrivacyInfo.xcprivacy; sourceTree = SOURCE_ROOT;}'))
resources.append(add('AppIcon', '{isa = PBXFileReference; lastKnownFileType = folder.icon; path = App/Resources/AppIcon.icon; sourceTree = SOURCE_ROOT;}'))
sdkpackage = add('sdk-package', '{isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/jellyfin/jellyfin-sdk-swift.git"; requirement = {kind = exactVersion; version = 3.1.0;};}')
signingconfig = add('SigningConfig', '{isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Configuration/Signing.xcconfig; sourceTree = SOURCE_ROOT;}')
targets = []; products = []
name = 'LibraVia'
product = add(name+'product','{isa = PBXFileReference; explicitFileType = wrapper.application; path = "LibraVia.app"; sourceTree = BUILT_PRODUCTS_DIR;}'); products.append(product)
sources = [add(name+f, '{isa = PBXBuildFile; fileRef = '+f+';}') for f in files]
res = [add(name+r, '{isa = PBXBuildFile; fileRef = '+r+';}') for r in resources]
sdkproduct = add(name+'sdk', '{isa = XCSwiftPackageProductDependency; package = '+sdkpackage+'; productName = JellyfinAPI;}')
sdkbuild = add(name+'sdkbuild', '{isa = PBXBuildFile; productRef = '+sdkproduct+';}')
phases = [add(name+'sources','{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = '+array(sources)+'; runOnlyForDeploymentPostprocessing = 0;}'),add(name+'resources','{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = '+array(res)+'; runOnlyForDeploymentPostprocessing = 0;}'),add(name+'frameworks','{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = '+array([sdkbuild])+'; runOnlyForDeploymentPostprocessing = 0;}')]
# One native multiplatform target and application identity on every platform.
settings = {
    'PRODUCT_NAME':'LibraVia',
    'PRODUCT_BUNDLE_IDENTIFIER':'com.chameleonenterprise.LibraVia',
    'SWIFT_VERSION':'5.0', 'GENERATE_INFOPLIST_FILE':'YES',
    'INFOPLIST_KEY_CFBundleDisplayName':'LibraVia',
    'MARKETING_VERSION':'0.2.0', 'CURRENT_PROJECT_VERSION':'54',
    'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon',
    'CODE_SIGN_STYLE':'Automatic', 'SWIFT_EMIT_LOC_STRINGS':'YES',
    'SDKROOT':'auto', 'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator macosx',
    'IPHONEOS_DEPLOYMENT_TARGET':'27.0', 'MACOSX_DEPLOYMENT_TARGET':'27.0',
    'TARGETED_DEVICE_FAMILY':'1,2', 'SUPPORTS_MACCATALYST':'NO',
    'INFOPLIST_KEY_UILaunchScreen_Generation[sdk=iphone*]':'YES',
    'INFOPLIST_KEY_UIApplicationSceneManifest_Generation[sdk=iphone*]':'YES',
    'INFOPLIST_KEY_UISupportedInterfaceOrientations[sdk=iphone*]':'UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight',
    'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad[sdk=iphone*]':'UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight',
    'INFOPLIST_KEY_LSApplicationCategoryType[sdk=macosx*]':'public.app-category.books',
    'ENABLE_HARDENED_RUNTIME[sdk=macosx*]':'YES',
    'ENABLE_APP_SANDBOX[sdk=macosx*]':'YES',
    'ENABLE_OUTGOING_NETWORK_CONNECTIONS[sdk=macosx*]':'YES',
}
configs=[]
for mode in ['Debug','Release']:
    s=settings | {'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O','DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym'}
    if mode=='Debug': s['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG'
    configs.append(add(name+mode,'{isa = XCBuildConfiguration; baseConfigurationReference = '+signingconfig+'; buildSettings = {'+' '.join(quote(k)+' = '+quote(v)+';' for k,v in s.items())+'}; name = '+mode+';}'))
configlist=add(name+'configs','{isa = XCConfigurationList; buildConfigurations = '+array(configs)+'; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;}')
targets.append(add(name,'{isa = PBXNativeTarget; buildConfigurationList = '+configlist+'; buildPhases = '+array(phases)+'; buildRules = (); dependencies = (); name = '+quote(name)+'; packageProductDependencies = '+array([sdkproduct])+'; productName = "LibraVia"; productReference = '+product+'; productType = "com.apple.product-type.application";}'))
products_group=add('products','{isa = PBXGroup; children = '+array(products)+'; name = Products; sourceTree = "<group>";}')
main=add('main','{isa = PBXGroup; children = '+array(files+resources+[signingconfig,products_group])+'; sourceTree = "<group>";}')
configs=[]
for mode in ['Debug','Release']:
    configs.append(add('project'+mode,'{isa = XCBuildConfiguration; buildSettings = {CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0;}; name = '+mode+';}'))
configlist=add('projectconfigs','{isa = XCConfigurationList; buildConfigurations = '+array(configs)+'; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;}')
project=add('project','{isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700;}; buildConfigurationList = '+configlist+'; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = '+main+'; packageReferences = '+array([sdkpackage])+'; productRefGroup = '+products_group+'; projectDirPath = ""; projectRoot = ""; targets = '+array(targets)+';}')
folder=root/'JellyfinBooks.xcodeproj'; folder.mkdir(exist_ok=True)
(folder/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(k+' = '+v+';' for k,v in objects.items())+'\n}; rootObject = '+project+';}\n')
for target in targets:
    name='LibraVia'
    dest=folder/'xcshareddata/xcschemes'; dest.mkdir(parents=True,exist_ok=True)
    ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="LibraVia.app" BlueprintName="{name}" ReferencedContainer="container:JellyfinBooks.xcodeproj"/>'
    (dest/(name+'.xcscheme')).write_text(f'''<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
# Retire only the two previously generated platform schemes.
for old in ['JellyfinBooks-iOS', 'JellyfinBooks-macOS']:
    (folder/'xcshareddata/xcschemes'/(old+'.xcscheme')).unlink(missing_ok=True)
print('Generated one LibraVia multiplatform target and scheme')
