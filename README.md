# Nook

Native macOS RSS reader draft built with SwiftUI, Swift 6, and Xcode.

## 현재 구성

- App framework: SwiftUI
- Language mode: Swift 6
- Local toolchain checked here: Xcode 26.5, Swift 6.3.2
- Deployment target: macOS 26.0
- Security baseline: App Sandbox enabled with read-only user-selected file access
- UI draft: 3-column RSS reader with sidebar feeds, article list, reader pane, inspector, native settings, toolbar actions, search, share sheet, context menus, and menu commands

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

대부분의 첫 작업은 `Nook/ContentView.swift`에서 시작하면 됩니다. 현재는 UI 검증용 목업 데이터가 들어 있고, 실제 RSS 기능은 아직 연결하지 않았습니다.

다음 구현 경계:

- `URLSession`으로 feed URL 가져오기
- RSS/Atom XML 파싱
- SwiftData로 feed/article/read state 저장
- OPML import/export
- Background refresh와 notification

앱이 더 오래된 macOS도 지원해야 한다면 `Nook.xcodeproj`의 `MACOSX_DEPLOYMENT_TARGET` 값을 낮추면 됩니다. 지금은 최신 로컬 개발 환경에 맞춰 `26.0`으로 설정했습니다.
