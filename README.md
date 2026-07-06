# DicyaninGamecenterWrapper

Game Center authentication, matchmaking, lobbies (CloudKit-backed global lobby list with push updates), and real-time match transport for iOS and visionOS.

## Setup checklist

Every one of these is required. Missing any of them produces vague auth errors.

1. App Store Connect: an app record must exist for the exact bundle ID, with Game Center enabled under Features.
2. Entitlements: `com.apple.developer.game-center` = true, plus CloudKit (`com.apple.developer.icloud-services` = CloudKit and your container in `com.apple.developer.icloud-container-identifiers`) and `aps-environment` for lobby push updates.
3. Info.plist MUST contain non-empty `CFBundleShortVersionString` and `CFBundleVersion`. See the 5001 fix below.
4. Create the service once at app launch and authenticate once:

```swift
import DicyaninGamecenterWrapper

@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(LobbyPushDelegate.self) private var pushDelegate
    @StateObject private var gameCenter: GameCenterService

    init() {
        let gc = GameCenterService(containerID: "iCloud.com.yourteam.yourapp")
        GameCenterService.shared = gc
        _gameCenter = StateObject(wrappedValue: gc)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(gameCenter: gameCenter)
                .task { gameCenter.authenticate() }
        }
    }
}
```

Call `authenticate()` exactly ONCE per launch. Re-setting `GKLocalPlayer.authenticateHandler` (e.g. from a lobby view's onAppear plus a Sign In button) makes GameKit fire the handler again with a spurious "error communicating with the server".

## Troubleshooting

### GKErrorDomain Code=3, GKServerStatusCode=5001: "Missing x-gk-bundle-version and x-gk-short-bundle-version"

THE FIX. This is the number one silent killer, hit in JohnnyCrazyPlane (July 2026).

Cause: the built app's Info.plist has empty or missing `CFBundleVersion` and `CFBundleShortVersionString`. Game Center sends these as HTTP headers on every auth request; the server rejects the request with status 5001 and GameKit surfaces it as the generic "error communicating with the server" (code 3). Everything else can be configured perfectly and auth will still fail every time.

This happens whenever a target uses `GENERATE_INFOPLIST_FILE: YES` without setting `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. Xcode's own templates set them; xcodegen does NOT.

Fix in project.yml (xcodegen), on EVERY target that uses the wrapper:

```yaml
settings:
  base:
    GENERATE_INFOPLIST_FILE: YES
    MARKETING_VERSION: "1.0"
    CURRENT_PROJECT_VERSION: "1"
```

Verify the built product before blaming anything else:

```bash
plutil -p /path/to/Built.app/Info.plist | grep -E "CFBundleVersion|CFBundleShortVersionString"
```

Both must print non-empty values.

### Code=3 "error communicating with the server" (no 5001)

Usually caused by calling `authenticate()` more than once per launch, which re-sets `GKLocalPlayer.authenticateHandler`. Guard it:

```swift
private var authRequested = false
func authenticate() {
    guard !authRequested else { return }
    authRequested = true
    service.authenticate()
}
```

Otherwise: genuine network or Apple server reachability.

### Code=6 notAuthenticated, sign-in sheet never appears

GameKit caches a declined sign-in per app and returns code 6 with a nil view controller forever after. Delete the app from the device, reinstall, launch fresh. Also make sure the device is signed into Game Center in Settings > Games.

### Code=15 gameUnrecognized

No App Store Connect record with Game Center enabled for this exact bundle ID, or the provisioning profile lacks the Game Center capability. Fix in App Store Connect > your app > Features, then rebuild with automatic signing.

### Changed bundle ID?

Treat it as a brand new app: new App Store Connect record with Game Center enabled, new iCloud container, delete and reinstall on device, and re-verify the 5001 Info.plist versions above.
