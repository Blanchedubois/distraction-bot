// Samples fixed points of an offscreen render (PLAN_DESIGN_CLEANUP §3.5): swiftc -O scripts/sample-shot.swift -o /tmp/sample && /tmp/sample docs/shots/<shot>.png

import AppKit
let args = CommandLine.arguments
let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: args[1])))!
let pts: [(String,Int,Int)] = [("page bg",20,20),("score card paper",1500,600),("session card (wash)",900,1200),("jump card",300,1700),("today card",1000,2300),("kpi tile",300,2600),("sidebar? n/a",10,10)]
for (n,x,y) in pts { if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { print(n, String(format:"#%02x%02x%02x", Int(c.redComponent*255), Int(c.greenComponent*255), Int(c.blueComponent*255))) } }
