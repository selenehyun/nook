# Nook

Native macOS RSS reader draft built with SwiftUI, Swift 6, and Xcode.

## 현재 구성

- App framework: SwiftUI
- Language mode: Swift 6
- Local toolchain checked here: Xcode 26.5, Swift 6.3.2
- Deployment target: macOS 26.0
- Security baseline: App Sandbox enabled with read-only user-selected file access
- UI: 3-column RSS reader with sidebar feeds, article list, reader pane, inspector, native settings, toolbar actions, search, share sheet, context menus, and menu commands
- Feed loading: real RSS/Atom fetching through `URLSession` and XML parsing
- Feed discovery: normal website URLs are checked for RSS/Atom `<link rel="alternate">` tags
- Storage: user-selected sync folder with `NookLibrary.json`, intended for an iCloud Drive folder
- Subscriptions: OPML import/export

Apple's current Xcode page is already highlighting Xcode 27. This repo is generated and build-verified with the Xcode version installed on this machine, Xcode 26.5. If you install Xcode 27 later, open the project in Xcode and accept the recommended project setting updates.

## 웹 개발자 기준으로 보면

- `Nook.xcodeproj`: `package.json`과 Vite/Webpack 설정을 합친 Xcode 프로젝트 파일입니다. 보통 Xcode가 관리합니다.
- Scheme `Nook`: `npm run dev`나 `npm run build`처럼 어떤 타깃을 실행/빌드할지 정하는 실행 설정입니다.
- Target `Nook`: 실제로 만들어지는 macOS 앱 번들입니다. 결과물은 `Nook.app`입니다.
- `Nook/NookApp.swift`: 앱의 entry point입니다. 웹으로 치면 `main.tsx` 또는 `App.tsx`를 마운트하는 파일에 가깝습니다.
- `Nook/ContentView.swift`: RSS reader UI 초안입니다. SwiftUI는 React처럼 선언형 UI를 쓰지만 런타임은 네이티브입니다.
- `Nook/Assets.xcassets`: 색상, 아이콘, 이미지 같은 앱 리소스 저장소입니다.
- `Nook/Nook.entitlements`: macOS 권한과 샌드박스 설정입니다.

## 실행

Xcode에서 실행:

1. `Nook.xcodeproj`를 엽니다.
2. 상단 Scheme이 `Nook`, 실행 대상이 `My Mac`인지 확인합니다.
3. `Command-R`로 실행합니다.

터미널에서 빌드:

```sh
make build
```

`make build`는 빠른 컴파일 확인용이라 코드 서명을 끄고 빌드합니다. 실제 앱 실행은 Xcode에서 `Command-R`로 하는 흐름이 가장 단순합니다.

Xcode 열기:

```sh
make open
```

## 처음 수정할 곳

대부분의 UI 작업은 `Nook/ContentView.swift`에서 시작하면 됩니다. Feed/article 상태와 persistence는 `Nook/ReaderStore.swift`, RSS/Atom fetching은 `Nook/RSSFeedService.swift`, sync-folder 저장은 `Nook/ReaderStorage.swift`에 있습니다.

## RSS와 iCloud 폴더 저장

1. 앱을 실행합니다.
2. toolbar의 folder 버튼으로 iCloud Drive 안의 폴더를 선택합니다.
3. 앱은 그 폴더에 `NookLibrary.json`을 만들고 feed, article, read state, starred state를 저장합니다.
4. `+` 버튼으로 RSS/Atom feed URL 또는 feed link가 있는 웹사이트 URL을 추가합니다.
5. Subscriptions 메뉴에서 OPML을 import/export할 수 있습니다.
6. Settings에서 automatic refresh와 refresh interval을 조정할 수 있습니다.

다음 구현 경계:

- App notification for new articles
- Better full-content extraction for feeds that only publish summaries
- Conflict handling if the same `NookLibrary.json` is edited by multiple Macs at once

앱이 더 오래된 macOS도 지원해야 한다면 `Nook.xcodeproj`의 `MACOSX_DEPLOYMENT_TARGET` 값을 낮추면 됩니다. 지금은 최신 로컬 개발 환경에 맞춰 `26.0`으로 설정했습니다.
