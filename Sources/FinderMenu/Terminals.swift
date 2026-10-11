import Foundation

/// How a terminal is asked to start in a folder.
enum TerminalLaunch {
    case openFolder // hand it the folder, like dropping the folder on its Dock icon
    case link((String) -> URL?) // the terminal's own URL scheme
    case arguments((String) -> [String]) // start a new instance with command-line arguments
}

/// Terminals that Open Terminal Here knows about. Unless one was picked with
/// `finder-menu terminal <app>`, the first installed one wins; Terminal is always there.
let terminals: [(id: String, name: String, launch: TerminalLaunch)] = [
    ("com.googlecode.iterm2", "iTerm2", .openFolder),
    ("com.mitchellh.ghostty", "Ghostty", .openFolder),
    ("dev.warp.Warp-Stable", "Warp", .link { dir in
        var c = URLComponents(string: "warp://action/new_tab")
        c?.queryItems = [URLQueryItem(name: "path", value: dir)]
        return c?.url
    }),
    ("com.github.wez.wezterm", "WezTerm", .arguments { ["start", "--cwd", $0] }),
    ("net.kovidgoyal.kitty", "kitty", .arguments { ["--directory", $0] }),
    ("org.alacritty", "Alacritty", .arguments { ["--working-directory", $0] }),
    ("com.apple.Terminal", "Terminal", .openFolder)
]
