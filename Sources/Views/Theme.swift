import SwiftUI
import UIKit

/// 配色は Web 版と同じ。ウォームアイボリー／墨色／錆青。
enum Theme {
    static let ivory = Color(red: 0.976, green: 0.973, blue: 0.961)   // #F9F8F5
    static let ink = Color(red: 0.102, green: 0.102, blue: 0.106)     // #1A1A1B
    static let accent = Color(red: 0.290, green: 0.416, blue: 0.478)  // #4A6A7A
    static let panel = Color(red: 0.949, green: 0.941, blue: 0.918)
    static let canvas = Color(red: 0.925, green: 0.914, blue: 0.886)
    static let paper = Color.white
    static let muted = Color(red: 0.102, green: 0.102, blue: 0.106).opacity(0.55)
}
