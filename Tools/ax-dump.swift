#!/usr/bin/env swift
// ax-dump.swift — Fase 0: cosa espone Serato DJ Pro tramite Accessibility.
// Sola lettura: legge attributi AX, non ne scrive nessuno sul processo di Serato.
//
// Uso (Serato aperto, permesso Accessibility concesso al Terminale):
//   swift Tools/ax-dump.swift                    albero completo della finestra (profondità 12)
//   swift Tools/ax-dump.swift --depth 25         profondità massima diversa
//   swift Tools/ax-dump.swift --attrs            elenca anche tutti i nomi di attributo per elemento
//   swift Tools/ax-dump.swift --menus            include la barra dei menu (esclusa di default)
//   swift Tools/ax-dump.swift --at-mouse 5       dopo 5 s descrive l'elemento sotto il cursore,
//                                                i suoi antenati e i suoi figli
//   swift Tools/ax-dump.swift --bundle <id>      altra app (default com.serato.seratodj)

import AppKit
import ApplicationServices

// MARK: - Argomenti

let arguments = CommandLine.arguments

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func flag(_ name: String) -> Bool { arguments.contains(name) }

let bundleID = option("--bundle") ?? "com.serato.seratodj"
let maxDepth = Int(option("--depth") ?? "") ?? 12
let maxChildren = Int(option("--max-children") ?? "") ?? 200
let showAttributeNames = flag("--attrs")
let includeMenus = flag("--menus")
let atMouseDelay = option("--at-mouse").flatMap(Double.init)

// MARK: - Permessi e processo

let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
guard AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) else {
    fputs("""
    Permesso Accessibility mancante.
    Impostazioni di Sistema → Privacy e sicurezza → Accessibilità: abilita il Terminale
    (o l'app da cui lanci lo script), poi rilancia.

    """, stderr)
    exit(1)
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    fputs("Nessun processo con bundle id \(bundleID) in esecuzione.\n", stderr)
    exit(1)
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)
// Il timeout vale solo per le nostre chiamate: non modifica nulla in Serato.
AXUIElementSetMessagingTimeout(appElement, 2.0)

// MARK: - Lettura attributi

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func attributeNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(element, &names) == .success, let names else { return [] }
    return names as? [String] ?? []
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func clean(_ text: String, limit: Int = 80) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: "⏎")
    return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
}

func describe(_ value: AnyObject?) -> String? {
    guard let value else { return nil }
    if let string = value as? String { return string.isEmpty ? nil : "\"\(clean(string))\"" }
    if let number = value as? NSNumber { return number.stringValue }
    if let array = value as? [AnyObject] { return "[\(array.count) elementi]" }
    if CFGetTypeID(value) == AXUIElementGetTypeID() { return "<elemento>" }
    if CFGetTypeID(value) == AXValueGetTypeID() {
        let axValue = value as! AXValue
        switch AXValueGetType(axValue) {
        case .cgPoint:
            var point = CGPoint.zero
            AXValueGetValue(axValue, .cgPoint, &point)
            return "(\(Int(point.x)), \(Int(point.y)))"
        case .cgSize:
            var size = CGSize.zero
            AXValueGetValue(axValue, .cgSize, &size)
            return "\(Int(size.width))×\(Int(size.height))"
        case .cgRect:
            var rect = CGRect.zero
            AXValueGetValue(axValue, .cgRect, &rect)
            return "(\(Int(rect.minX)), \(Int(rect.minY))) \(Int(rect.width))×\(Int(rect.height))"
        case .cfRange:
            var range = CFRange()
            AXValueGetValue(axValue, .cfRange, &range)
            return "range \(range.location)+\(range.length)"
        default:
            return "<AXValue>"
        }
    }
    return String(describing: value)
}

// MARK: - Statistiche

var elementCount = 0
var textElementCount = 0
var roleCounts: [String: Int] = [:]
var textSamples: [String] = []

func summaryLine(_ element: AXUIElement) -> String {
    let role = attribute(element, kAXRoleAttribute) as? String ?? "?"
    var parts = [role]
    if let subrole = attribute(element, kAXSubroleAttribute) as? String { parts.append("[\(subrole)]") }

    let textual: [(String, String)] = [
        ("title", kAXTitleAttribute),
        ("value", kAXValueAttribute),
        ("desc", kAXDescriptionAttribute),
        ("help", kAXHelpAttribute),
        ("id", kAXIdentifierAttribute),
    ]
    var hasText = false
    for (label, name) in textual {
        guard let text = describe(attribute(element, name)) else { continue }
        parts.append("\(label)=\(text)")
        if label != "id", text.hasPrefix("\"") {
            hasText = true
            if textSamples.count < 30 { textSamples.append("\(role) \(label)=\(text)") }
        }
    }

    if let position = describe(attribute(element, kAXPositionAttribute)),
       let size = describe(attribute(element, kAXSizeAttribute)) {
        parts.append("@\(position) \(size)")
    }

    let childCount = children(element).count
    if childCount > 0 { parts.append("figli=\(childCount)") }

    elementCount += 1
    roleCounts[role, default: 0] += 1
    if hasText { textElementCount += 1 }
    return parts.joined(separator: " ")
}

// MARK: - Dump

func dump(_ element: AXUIElement, depth: Int = 0) {
    let indent = String(repeating: "  ", count: depth)
    print(indent + summaryLine(element))
    if showAttributeNames {
        print(indent + "  · attributi: " + attributeNames(element).joined(separator: ", "))
    }

    guard depth < maxDepth else {
        if !children(element).isEmpty { print(indent + "  … profondità massima raggiunta") }
        return
    }

    let kids = children(element)
    for child in kids.prefix(maxChildren) {
        if !includeMenus, attribute(child, kAXRoleAttribute) as? String == kAXMenuBarRole { continue }
        dump(child, depth: depth + 1)
    }
    if kids.count > maxChildren {
        print(indent + "  … altri \(kids.count - maxChildren) figli omessi")
    }
}

func printSummary() {
    print("\n=== Riepilogo ===")
    print("Elementi visitati: \(elementCount)")
    print("Elementi con testo: \(textElementCount)")
    print("Ruoli: " + roleCounts.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
    if !textSamples.isEmpty {
        print("Campioni di testo:")
        textSamples.forEach { print("  \($0)") }
    }
    let tableLike = ["AXTable", "AXOutline", "AXRow", "AXCell", "AXList"].contains { roleCounts[$0] != nil }
    print(tableLike
        ? "→ Ci sono ruoli tabellari: verifica se le righe contengono titolo/artista (strada AX)."
        : "→ Nessun ruolo tabellare: il browser è probabilmente disegnato in proprio (strada OCR).")
}

// MARK: - Modalità

if let delay = atMouseDelay {
    print("Porta il cursore su una riga del browser di Serato…")
    var remaining = Int(delay.rounded(.up))
    while remaining > 0 {
        print("  \(remaining)…")
        Thread.sleep(forTimeInterval: 1)
        remaining -= 1
    }

    // CGEvent restituisce coordinate globali con origine in alto a sinistra, come AX.
    let mouse = CGEvent(source: nil)?.location ?? .zero
    print("Cursore a (\(Int(mouse.x)), \(Int(mouse.y)))\n")

    var hit: AXUIElement?
    let result = AXUIElementCopyElementAtPosition(appElement, Float(mouse.x), Float(mouse.y), &hit)
    guard result == .success, let hit else {
        print("Nessun elemento AX in quel punto (errore \(result.rawValue)).")
        print("→ Serato non espone quella zona: strada OCR.")
        exit(0)
    }

    var pid: pid_t = 0
    AXUIElementGetPid(hit, &pid)
    if pid != app.processIdentifier {
        print("Attenzione: l'elemento appartiene al pid \(pid), non a Serato (\(app.processIdentifier)).")
    }

    print("--- Antenati (dalla finestra all'elemento) ---")
    var chain: [AXUIElement] = []
    var current: AXUIElement? = hit
    while let element = current {
        chain.insert(element, at: 0)
        current = attribute(element, kAXParentAttribute).map { $0 as! AXUIElement }
        if chain.count > 50 { break }
    }
    for (depth, element) in chain.enumerated() {
        print(String(repeating: "  ", count: depth) + summaryLine(element))
    }

    print("\n--- Elemento sotto il cursore e discendenti ---")
    print("Attributi: " + attributeNames(hit).joined(separator: ", "))
    dump(hit)
    printSummary()
} else {
    print("Serato: pid \(app.processIdentifier), bundle \(bundleID)\n")
    dump(appElement)
    printSummary()
}
