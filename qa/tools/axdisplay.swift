import AppKit

// Prints the primary display's visibleFrame as x,y,w,h in AX coords (origin top-left of the primary display).
guard let primary = NSScreen.screens.first else {
    fputs("no screen\n", stderr)
    exit(1)
}
let visible = primary.visibleFrame
let full = primary.frame
print("\(Int(visible.minX)),\(Int(full.maxY - visible.maxY)),\(Int(visible.width)),\(Int(visible.height))")
