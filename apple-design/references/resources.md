# Apple design resources

The parts of <https://developer.apple.com/design/> that are not the HIG: design kits, fonts,
symbols, tools, and the learning pathway. Checked 2026-09-14; the page is plain HTML with no data
endpoint, so this list is hand-kept. Re-open the page when a kit's version number below looks old
(Apple refreshes kits each June at WWDC).

## Design kits — <https://developer.apple.com/design/resources/>

Official component libraries and templates, one per platform release.

| Platform | Kit | Formats |
| --- | --- | --- |
| iOS 27 / iPadOS 27 | UI kit | [Figma](https://www.figma.com/community/file/1651309003795292092/ios-and-ipados-27), [Sketch](https://www.sketch.com/s/04c24d8b-38fb-4afb-8836-36617e022f02) |
| iOS 27 / iPadOS 27 / watchOS 27 | App icon template | [Figma](https://www.figma.com/community/file/1645923469870515372/app-icon-template-ios-ipados-and-watchos-27), [Sketch](https://sketch.com/s/a443d962-d989-4c5b-b1db-fb7fb3946995), [Photoshop + Illustrator](https://devimages-cdn.apple.com/design/resources/download/iOS-27-Icon-Templates-Photoshop-Illustrator.dmg) |
| macOS 27 | UI kit | [Figma](https://www.figma.com/community/file/1651309434229735362/macos-27), [Sketch](https://sketch.com/s/57153a31-3379-4737-8ac6-dbfd6525f052) |
| watchOS 26 | UI kit | [Figma](https://www.figma.com/community/file/1540060090060216489/watchos-26), [Sketch](https://sketch.com/s/2b12618d-596c-41fd-8488-132bff9535e7) |
| visionOS 26 | UI kit | [Figma](https://www.figma.com/community/file/1540071341298017505/visionos-26), [Sketch](https://sketch.com/s/eb13bfe1-2ddb-4f87-b92c-740a36abed7a) |
| tvOS 18 | Design + production templates | Sketch and Photoshop `.dmg` downloads on the resources page |

Technology kits (Figma + Sketch) exist for Apple Pay, App Clips, Live Activities, iMessage apps
and stickers, Sign in with Apple, Siri App Shortcuts, Tap to Pay on iPhone, TipKit, and Wallet;
glyph and logo packs for AirPlay, ARKit, Apple Health, Game Center, HomeKit, Siri, and Sign in
with Apple. Each sits beside its HIG page's `Design Guidelines` link on the resources page.

## Fonts

System typefaces, licensed for designing and developing Apple-platform software only.

| Font | Role | Download |
| --- | --- | --- |
| SF Pro | System font for iOS, iPadOS, macOS, tvOS | <https://devimages-cdn.apple.com/design/resources/download/SF-Pro.dmg> |
| SF Compact | watchOS system font; small sizes and narrow columns | <https://devimages-cdn.apple.com/design/resources/download/SF-Compact.dmg> |
| SF Mono | Xcode's monospace | <https://devimages-cdn.apple.com/design/resources/download/SF-Mono.dmg> |
| New York | Serif; reading face small, display face large | <https://devimages-cdn.apple.com/design/resources/download/NY.dmg> |
| SF Arabic / Armenian / Georgian / Hebrew | Script-specific system fonts | `SF-Arabic.dmg`, `SF-Armenian.dmg`, `SF-Georgian.dmg`, `SF-Hebrew.dmg` at the same path |

Sizes, weights, and Dynamic Type tables: `hig/typography.md › Specifications`.

## SF Symbols — <https://developer.apple.com/sf-symbols/>

The icon set the HIG means whenever it says *symbol*: thousands of glyphs in nine weights that
align with SF Pro. The app browses, previews, and exports them; `hig/sf-symbols.md` is the usage
guidance and `hig/icons.md › Standard icons` lists the symbols for common actions.

- [SF Symbols 8 beta](https://devimages-cdn.apple.com/design/resources/download/SF-Symbols-8.dmg?2) and [SF Symbols 7](https://devimages-cdn.apple.com/design/resources/download/SF-Symbols-7.dmg?2), macOS Sonoma or later.

## Icon Composer — <https://developer.apple.com/icon-composer/>

Apple's app for building layered app icons that render across every platform's appearance
variants (light, dark, tinted, clear) from one source. Download via
<https://developer.apple.com/download/all/?q=Icon%20Composer>; macOS Sequoia or later. Guidance:
`hig/app-icons.md`.

## Product bezels

Device frames (Photoshop + PNG) for screenshots and marketing: current iPhone, iPad, Mac, Apple
Watch, Apple TV, and Studio Display models, plus a Keynote live-video bezel. Listed under
"Product Bezels" on the resources page; usage terms in Apple's
[Marketing Resources and Identity Guidelines](https://developer.apple.com/app-store/marketing/guidelines/#section-products).
Badges and logos for Apple technologies: <https://developer.apple.com/licensing-trademarks/>.

## Learning pathway — <https://developer.apple.com/design/get-started/>

Apple's own ordering for someone new to its design language, all WWDC sessions:

1. [The qualities of great design](https://developer.apple.com/videos/play/wwdc2018/801/)
2. [Essential design principles](https://developer.apple.com/videos/play/wwdc2017/802/)
3. [Design foundations from idea to interface](https://developer.apple.com/videos/play/wwdc2025/359/)
4. [Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/) — the Liquid Glass design system
5. Prototyping: [Fake it till you make it](https://developer.apple.com/videos/play/wwdc2014/223/), [60-second prototyping](https://developer.apple.com/videos/play/wwdc2017/818/), [Design with SwiftUI](https://developer.apple.com/videos/play/wwdc2023/10115/)

All design sessions: <https://developer.apple.com/videos/design>. Recent guidance changes:
<https://developer.apple.com/design/whats-new/>, or the `Last changed` column in `hig-index.md`.
Apple Design Award winners, as worked examples of the principles:
<https://developer.apple.com/design/awards/>.
