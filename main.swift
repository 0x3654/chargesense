// ChargeSense — заряд DualSense в строке меню macOS + индикация на самом
// контроллере: цвет lightbar и шкала из 5 player-LED.
//
// Чтение: HID GET_REPORT (input 0x31 по Bluetooth / 0x01 по USB), раскладка как в
// драйвере Linux hid-playstation.c: батарея — байт 54 (BT) / 53 (USB):
// младший нибл = ёмкость (×10+5 %), старший — состояние зарядки.
//
// Запись: output-отчёт 0x31 (BT, 78 байт, CRC32 seed 0xA2 в хвосте) / 0x02
// (USB, 63 байта, без CRC): valid_flag1 BIT(2) = lightbar, BIT(4) = player LEDs;
// RGB @ +44..46, player_leds @ +43 общего блока.
//
// Индикация (настраивается галками, обе вкл по умолчанию):
// — цветами: от батареи — зоны (≤15% красный дыханием, ≤25% красный, ≤35%
//   оранжевый, ≤75% синий, выше зелёный); на зарядке — окна по 2 с: жёлтый
//   вздох ⇄ цвет зоны (статика с плавным входом или пульс)
// — точками: 5 player-LED = зоны по 20%; при зарядке мигает верхняя (текущая)
//   точка, набранные — горят; при полном — все пять горят

import AppKit
import IOKit
import IOKit.hid
import ServiceManagement
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    struct LedSpec: Equatable {
        let pulsing: Bool
        let r: UInt8, g: UInt8, b: UInt8
        let period: Double
        let label: String
    }

    private var item: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var colorsItem: NSMenuItem!
    private var dotsItem: NSMenuItem!
    private var autostartItem: NSMenuItem!
    private var timer: Timer?
    private var dev: IOHIDDevice?
    private let reportBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
    private var lastPct = -1
    private var lastCharging = false
    private var appliedZone: LedSpec?
    private var appliedPlugged = false
    private var ledTimer: Timer?
    private var reaffirmTimer: Timer?
    private var outSeq: UInt8 = 0

    // демо-прогон (для записи видео)
    private var demoRunning = false
    private var demoTimer: Timer?
    private var demoT0 = Date()
    private var demoSteps: [(dur: Double, tick: (Double) -> Void)] = []
    private let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)

    func applicationDidFinishLaunching(_ n: Notification) {
        UserDefaults.standard.register(defaults: ["ds5.ledColors": true, "ds5.ledDots": true])
        let colorsEnabled = UserDefaults.standard.bool(forKey: "ds5.ledColors")
        let dotsEnabled = UserDefaults.standard.bool(forKey: "ds5.ledDots")

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        statusLine = NSMenuItem(title: L("not_connected"), action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(NSMenuItem.separator())
        colorsItem = menu.addItem(withTitle: L("colors"), action: #selector(toggleColors(_:)), keyEquivalent: "")
        colorsItem.target = self
        colorsItem.state = colorsEnabled ? .on : .off
        dotsItem = menu.addItem(withTitle: L("dots"), action: #selector(toggleDots(_:)), keyEquivalent: "")
        dotsItem.target = self
        dotsItem.state = dotsEnabled ? .on : .off
        autostartItem = menu.addItem(withTitle: L("autostart"), action: #selector(toggleAutostart(_:)), keyEquivalent: "")
        autostartItem.target = self
        autostartItem.state = Self.autostartOn() ? .on : .off
        let demoItem = menu.addItem(withTitle: L("demo"), action: #selector(runDemo), keyEquivalent: "")
        demoItem.target = self
        menu.addItem(NSMenuItem.separator())
        let refreshItem = menu.addItem(withTitle: L("refresh"), action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: L("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        updateTitle(nil)

        // DualSense Edge 054c:0df2 + обычный DualSense 054c:0ce6
        let dicts = [[kIOHIDVendorIDKey as String: 1356, kIOHIDProductIDKey as String: 3570],
                     [kIOHIDVendorIDKey as String: 1356, kIOHIDProductIDKey as String: 3302]] as CFArray
        IOHIDManagerSetDeviceMatchingMultiple(mgr, dicts)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let onAdd: IOHIDDeviceCallback = { ctx, _, _, device in
            guard let ctx = ctx else { return }
            let app = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            IOHIDDeviceOpen(device, 0)
            app.dev = device
            app.appliedZone = nil  // контроллер при переподключении сбрасывает подсветку — выставим заново
            app.lastPct = -1
            app.attachReports(device)
            NSLog("ds5batt: контроллер подключён")
            app.refresh()
        }
        let onRemove: IOHIDDeviceCallback = { ctx, _, _, device in
            guard let ctx = ctx else { return }
            let app = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            // дребезг переключения USB⇄BT: ушёл один девайс, а в менеджере жив другой
            // (напр. onAdd USB уже успел прийти, затем onRemove старого BT) —
            // перецепляемся на оставшийся, иначе свет замолкает при живом чтении
            if let set = IOHIDManagerCopyDevices(app.mgr) as? Set<IOHIDDevice>,
               let d = set.first(where: { $0 != device }) {
                if d != app.dev {
                    IOHIDDeviceOpen(d, 0)
                    app.dev = d
                    app.attachReports(d)
                    app.appliedZone = nil   // выставим индикацию заново
                }
                app.refresh()
                return
            }
            app.dev = nil
            app.lastPct = -1
            app.appliedZone = nil
            app.appliedPlugged = false
            app.cancelDemo()
            app.stopLedPulse()
            app.updateTitle(nil)
        }
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, onAdd, me)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, onRemove, me)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, 0)

        // страховка: если attach-колбэк уже не придёт (устройство подключено до старта)
        if let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let d = set.first {
            IOHIDDeviceOpen(d, 0)
            dev = d
            attachReports(d)
        }
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }

        // агрессивное пере-утверждение цвета: раз в 1с, чтобы перебивать редкие записи
        // сторонних (игры через GCController красят lightbar под фракцию); анимации
        // (пульс, окна зарядки) уже пишутся своим таймером каждые 0.12с
        reaffirmTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.dev == nil { self.reattachIfPossible() }
            else { self.reaffirmColor() }
        }
    }

    // ленивое восстановление после race: onRemove мог обнулить dev, когда новый
    // девайс ещё не появился в снапшоте менеджера, а повторного onAdd не будет —
    // раз в секунду пробуем перецепиться на живой девайс из сета
    private func reattachIfPossible() {
        guard dev == nil, let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let d = set.first else { return }
        IOHIDDeviceOpen(d, 0)
        dev = d
        attachReports(d)
        appliedZone = nil   // выставим индикацию заново
        refresh()
    }

    private func reaffirmColor() {
        guard !demoRunning, dev != nil, colorsEnabled, let zone = appliedZone else { return }
        if ledTimer != nil { return }   // идёт анимация — она уже пишет постоянно
        sendLightbar(zone.r, zone.g, zone.b, scale: 1)
    }

    private var colorsEnabled: Bool {
        UserDefaults.standard.bool(forKey: "ds5.ledColors")
    }
    private var dotsEnabled: Bool {
        UserDefaults.standard.bool(forKey: "ds5.ledDots")
    }

    private func L(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }

    private static func autostartOn() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    @objc private func toggleAutostart(_ sender: NSMenuItem) {
        let want = sender.state != .on
        if #available(macOS 13.0, *) {
            do {
                if want { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("ds5batt: autostart error: \(error.localizedDescription)")
            }
            sender.state = Self.autostartOn() ? .on : .off
        }
        NSLog("ds5batt: autostart = \(sender.state == .on)")
    }

    @objc private func toggleColors(_ sender: NSMenuItem) {
        sender.state = sender.state == .on ? .off : .on
        UserDefaults.standard.set(sender.state == .on, forKey: "ds5.ledColors")
        NSLog("ds5batt: подсветка цветами = \(sender.state == .on)")
        restartLed()
    }

    @objc private func toggleDots(_ sender: NSMenuItem) {
        sender.state = sender.state == .on ? .off : .on
        UserDefaults.standard.set(sender.state == .on, forKey: "ds5.ledDots")
        NSLog("ds5batt: шкала точками = \(sender.state == .on)")
        restartLed()
    }

    @objc func refresh() {
        if let bat = readBattery() { onBattery(pct: bat.pct, state: bat.state) }
        else if dev == nil { lastPct = -1; updateTitle(nil) }
        // GET не прошёл, но контроллер на связи (USB-стрим обновит сам) — держим последний статус;
        // пере-утверждение цвета переехало в отдельный 1с-таймер (reaffirmColor)
    }

    private func onBattery(pct: Int, state: Int) {
        let plugged = state >= 1
        guard pct != lastPct || plugged != lastCharging else { return }
        if plugged && !lastCharging && lastPct != -1 && !demoRunning { chargeBuzz() }
        lastPct = pct; lastCharging = plugged
        updateTitle((pct, plugged))
        let zone = Self.ledZone(pct: pct)
        let changed = zone != appliedZone || plugged != appliedPlugged
        appliedZone = zone
        appliedPlugged = plugged
        if changed && !demoRunning { restartLed() }
    }

    // зоны от батареи: ≤15% красный дыханием, ≤25% красный, ≤35% оранжевый,
    // ≤75% синий, выше — зелёный. Оттенки без «уезжания»: зелёный без синевы,
    // жёлтый без красноты (зарядка).
    private static func ledZone(pct: Int) -> LedSpec {
        switch pct {
        case ...15: return LedSpec(pulsing: true,  r: 255, g: 40,  b: 0, period: 4.0,
                                   label: "красный (критично)")
        case ...25: return LedSpec(pulsing: false, r: 255, g: 40,  b: 0, period: 0, label: "красный")
        case ...35: return LedSpec(pulsing: false, r: 255, g: 120, b: 0, period: 0, label: "оранжевый")
        case ...75: return LedSpec(pulsing: false, r: 0,   g: 80,  b: 255, period: 0, label: "синий")
        default:    return LedSpec(pulsing: false, r: 0,   g: 255, b: 0, period: 0, label: "зелёный")
        }
    }

    private static let chargeYellow = (r: UInt8(255), g: UInt8(235), b: UInt8(0))

    // 0.5 - 0.5*cos(2πu): 0 → 1 → 0, полный «вздох» на u ∈ [0,1]
    private static func breath(_ u: Double) -> Double { 0.5 - 0.5 * cos(2 * Double.pi * u) }

    private func restartLed() {
        stopLedPulse()
        guard let zone = appliedZone, dev != nil else { return }
        let dotsOn = dotsEnabled

        if !colorsEnabled {
            // свет выключен: точки статикой (или миганием при зарядке), lightbar гасим
            if dotsOn && lastCharging && lastPct < 100 {
                NSLog("ds5batt: led → только точки, мигаем текущей зоной")
                ledTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                    self?.sendLightbar(0, 0, 0, scale: 1)
                }
            } else {
                NSLog("ds5batt: led → только точки")
                sendLightbar(0, 0, 0, scale: 1)
            }
            return
        }

        if !appliedPlugged {
            // от батареи: пульс — синус 18–100% своим периодом, статика — одним отчётом
            if zone.pulsing {
                NSLog("ds5batt: led → \(zone.label), дыхание \(zone.period)с")
                let period = zone.period
                ledTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    let u = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                    self.sendLightbar(zone.r, zone.g, zone.b, scale: 0.18 + 0.82 * Self.breath(u))
                }
            } else {
                NSLog("ds5batt: led → \(zone.label)")
                sendLightbar(zone.r, zone.g, zone.b, scale: 1)
            }
            return
        }

        // на зарядке: окна по 2 с — жёлтый вздох ⇄ цвет зоны (статика с плавным входом / пульс)
        NSLog("ds5batt: led → на зарядке: жёлтый вздох ⇄ \(zone.label)")
        ledTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let t = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.0)
            if t < 2 {
                self.sendLightbar(Self.chargeYellow.r, Self.chargeYellow.g, Self.chargeYellow.b,
                                  scale: 0.18 + 0.82 * Self.breath(t / 2))
            } else if zone.pulsing {
                self.sendLightbar(zone.r, zone.g, zone.b,
                                  scale: 0.18 + 0.82 * Self.breath((t - 2) / 2))
            } else {
                let k = min(1, (t - 2) / 0.5)          // плавный вход в статику за 0.5 с
                self.sendLightbar(zone.r, zone.g, zone.b, scale: k * k * (3 - 2 * k))
            }
        }
    }

    private func stopLedPulse() {
        ledTimer?.invalidate()
        ledTimer = nil
    }

    // короткое жужжание при подключении зарядки (~0.2с)
    private var buzzTimer: Timer?

    private func chargeBuzz() {
        buzzTimer?.invalidate()
        var i = 0
        buzzTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            i += 1
            self.sendRumble(i <= 2 ? 255 : 0)
            if i > 2 { t.invalidate() }
        }
        NSLog("ds5batt: зарядка подключена — жужжим")
    }

    // только моторы: valid_flag1 = 0, свет/точки не трогаем
    private func sendRumble(_ level: UInt8) {
        guard let dev = dev else { return }
        outSeq = (outSeq &+ 1) & 0x0F
        if (IOHIDDeviceGetProperty(dev, "Transport" as CFString) as? String) == "USB" {
            var usb = [UInt8](repeating: 0, count: 63)
            usb[0] = 0x02
            if level > 0 {
                usb[1] = 0x03          // HAPTICS_SELECT + COMPATIBLE_VIBRATION
                usb[1 + 2] = level
                usb[1 + 3] = level
            }
            _ = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x02, usb, 63)
            return
        }
        var bt = [UInt8](repeating: 0, count: 78)
        bt[0] = 0x31
        bt[1] = outSeq << 4
        bt[2] = 0x10
        if level > 0 {
            bt[3] = 0x03              // HAPTICS_SELECT + COMPATIBLE_VIBRATION
            bt[3 + 2] = level
            bt[3 + 3] = level
        }
        let crc = ~Self.crc32le([0xA2] + bt[0..<74])
        bt[74] = UInt8(truncatingIfNeeded: crc)
        bt[75] = UInt8(truncatingIfNeeded: crc >> 8)
        bt[76] = UInt8(truncatingIfNeeded: crc >> 16)
        bt[77] = UInt8(truncatingIfNeeded: crc >> 24)
        _ = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x31, bt, 78)
    }

    // MARK: - демо-прогон (для записи видео)

    private static func dotsSolid(_ n: Int) -> UInt8 { UInt8((1 << n) - 1) }
    private static func dotsBlink(_ n: Int, _ t: Double) -> UInt8 {
        let on = t.truncatingRemainder(dividingBy: 1.2) < 0.6
        return UInt8((1 << (n - 1)) - 1) | (on ? UInt8(1 << (n - 1)) : 0)
    }

    // сценарий: зоны по 2с → на зарядке полный цикл (2с жёлтый вздох ⇄ 2с зона) →
    // только точки с миганием по 2с → финал: строб всеми цветами + все точки + вибрация
    @objc private func runDemo() {
        guard dev != nil else { NSLog("ds5batt: демо — контроллер не подключён"); return }
        if demoRunning { cancelDemo(); return }
        demoRunning = true
        stopLedPulse()
        demoT0 = Date()

        let zones: [(spec: LedSpec, n: Int)] = [(5, 1), (25, 2), (30, 2), (55, 3), (90, 5)]
            .map { (Self.ledZone(pct: $0.0), $0.1) }
        demoSteps = []

        for z in zones {
            demoSteps.append((dur: 2.0, tick: { [weak self] t in
                guard let self = self else { return }
                if z.spec.pulsing {
                    self.sendLightbar(z.spec.r, z.spec.g, z.spec.b,
                                      scale: 0.18 + 0.82 * Self.breath(t / 2), dots: Self.dotsSolid(z.n))
                } else {
                    self.sendLightbar(z.spec.r, z.spec.g, z.spec.b, scale: 1, dots: Self.dotsSolid(z.n))
                }
            }))
        }

        for z in zones {
            demoSteps.append((dur: 4.0, tick: { [weak self] t in
                guard let self = self else { return }
                let dots = Self.dotsBlink(z.n, t)
                if t < 2 {
                    self.sendLightbar(Self.chargeYellow.r, Self.chargeYellow.g, Self.chargeYellow.b,
                                      scale: 0.18 + 0.82 * Self.breath(t / 2), dots: dots)
                } else if z.spec.pulsing {
                    self.sendLightbar(z.spec.r, z.spec.g, z.spec.b,
                                      scale: 0.18 + 0.82 * Self.breath((t - 2) / 2), dots: dots)
                } else {
                    let k = min(1, (t - 2) / 0.5)
                    self.sendLightbar(z.spec.r, z.spec.g, z.spec.b, scale: k * k * (3 - 2 * k), dots: dots)
                }
            }))
        }

        for n in 1...5 {
            demoSteps.append((dur: 2.0, tick: { [weak self] t in
                self?.sendLightbar(0, 0, 0, scale: 1, dots: Self.dotsBlink(n, t))
            }))
        }

        let strobe: [(UInt8, UInt8, UInt8)] = [
            (255, 0, 0), (255, 120, 0), (255, 235, 0), (0, 255, 0),
            (0, 255, 255), (0, 80, 255), (255, 0, 255), (255, 255, 255)
        ]
        demoSteps.append((dur: 6.0, tick: { [weak self] t in
            guard let self = self else { return }
            let c = strobe[Int(t / 0.25) % strobe.count]
            let on = t.truncatingRemainder(dividingBy: 0.5) < 0.25
            self.sendLightbar(c.0, c.1, c.2, scale: 1, dots: on ? 31 : 0, rumble: on ? 255 : 0)
        }))

        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.dev != nil else { self.cancelDemo(); return }
            let t = -self.demoT0.timeIntervalSinceNow
            var acc = 0.0
            for s in self.demoSteps {
                if t < acc + s.dur { s.tick(t - acc); return }
                acc += s.dur
            }
            self.cancelDemo()
        }
        NSLog("ds5batt: демо пошла (\(demoSteps.count) шагов)")
    }

    private func cancelDemo() {
        demoTimer?.invalidate()
        demoTimer = nil
        demoSteps = []
        if demoRunning {
            demoRunning = false
            NSLog("ds5batt: демо закончена")
            restartLed()
        }
    }

    // поток input-отчётов: по USB GET_REPORT(input) прошивка не отдаёт — только стрим
    private func attachReports(_ device: IOHIDDevice) {
        let me = Unmanaged.passUnretained(self).toOpaque()
        let onReport: IOHIDReportCallback = { ctx, res, _, _, rid, data, len in
            guard res == kIOReturnSuccess, let ctx = ctx, rid == 0x31 || rid == 0x01 else { return }
            let off = rid == 0x31 ? 54 : 53
            guard len > off else { return }
            let b = data[off], cap = Int(b & 0x0F), st = Int(b >> 4)
            guard st <= 2, cap <= 10 else { return }
            let app = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            app.onBattery(pct: st == 2 ? 100 : min(cap * 10 + 5, 100), state: st)
        }
        IOHIDDeviceRegisterInputReportCallback(device, reportBuf, 128, onReport, me)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    private func readBattery() -> (pct: Int, state: Int)? {
        guard let dev = dev else { return nil }
        var buf = [UInt8](repeating: 0, count: 78)
        for (rid, len, off) in [(0x31, 78, 54), (0x01, 64, 53)] {  // BT 0x31, USB 0x01
            var n: CFIndex = len
            if IOHIDDeviceGetReport(dev, kIOHIDReportTypeInput, rid, &buf, &n) == kIOReturnSuccess, n > off {
                let b = buf[off]
                return (pct: Int(b >> 4) == 2 ? 100 : min(Int(b & 0x0F) * 10 + 5, 100),
                        state: Int(b >> 4))
            }
        }
        return nil
    }

    // MARK: - запись подсветки

    private func sendLightbar(_ r0: UInt8, _ g0: UInt8, _ b0: UInt8, scale: Double,
                              dots forcedDots: UInt8? = nil, rumble: UInt8 = 0) {
        guard let dev = dev else { return }
        let r = UInt8(Double(r0) * scale), g = UInt8(Double(g0) * scale), b = UInt8(Double(b0) * scale)

        // player LEDs: шкала заряда, точка = 20%; при зарядке верхняя (текущая) мигает
        var dots: UInt8 = 0
        if let forced = forcedDots {
            dots = forced
        } else if dotsEnabled, (1...100).contains(lastPct) {
            let n = max(1, min(5, (lastPct + 19) / 20))
            if lastCharging && lastPct < 100 {
                let on = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) < 0.6
                dots = UInt8((1 << (n - 1)) - 1) | (on ? UInt8(1 << (n - 1)) : 0)
            } else {
                dots = UInt8((1 << n) - 1)
            }
        }

        outSeq = (outSeq &+ 1) & 0x0F

        // USB: output 0x02 (63 байта), общий блок с +1, без CRC.
        // Формат выбираем по транспорту: слать 0x31 USB-девайсу нельзя — стек macOS
        // принимает такой SetReport (success), но контроллер его молча игнорирует.
        if (IOHIDDeviceGetProperty(dev, "Transport" as CFString) as? String) == "USB" {
            var usb = [UInt8](repeating: 0, count: 63)
            usb[0] = 0x02
            usb[1 + 1] = 0x14
            if rumble > 0 {
                usb[1] = 0x03          // valid_flag0: HAPTICS_SELECT + COMPATIBLE_VIBRATION
                usb[1 + 2] = rumble    // motor_right
                usb[1 + 3] = rumble    // motor_left
            }
            usb[1 + 43] = dots
            usb[1 + 44] = r; usb[1 + 45] = g; usb[1 + 46] = b
            _ = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x02, usb, 63)
            return
        }

        // Bluetooth: output 0x31 (78 байт), общий блок с +3, CRC32 (seed 0xA2) в хвосте
        var bt = [UInt8](repeating: 0, count: 78)
        bt[0] = 0x31
        bt[1] = outSeq << 4        // старший нибл — seq, инкремент на каждый отчёт
        bt[2] = 0x10               // tag обязателен
        bt[3 + 1] = 0x14           // valid_flag1: BIT(2) lightbar + BIT(4) player LEDs
        if rumble > 0 {
            bt[3] = 0x03           // valid_flag0: HAPTICS_SELECT + COMPATIBLE_VIBRATION
                                    // (без HAPTICS_SELECT моторы игнорируют вибрацию)
            bt[3 + 2] = rumble     // motor_right
            bt[3 + 3] = rumble     // motor_left
        }
        bt[3 + 43] = dots          // player_leds: N точек
        bt[3 + 44] = r; bt[3 + 45] = g; bt[3 + 46] = b
        let crc = ~Self.crc32le([0xA2] + bt[0..<74])
        bt[74] = UInt8(truncatingIfNeeded: crc)
        bt[75] = UInt8(truncatingIfNeeded: crc >> 8)
        bt[76] = UInt8(truncatingIfNeeded: crc >> 16)
        bt[77] = UInt8(truncatingIfNeeded: crc >> 24)
        if IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x31, bt, 78) == kIOReturnSuccess { return }

        // фолбэк, если BT-формат отклонён
        var usb = [UInt8](repeating: 0, count: 63)
        usb[0] = 0x02
        usb[1 + 1] = 0x14
        if rumble > 0 {
            usb[1] = 0x01
            usb[1 + 2] = rumble
            usb[1 + 3] = rumble
        }
        usb[1 + 43] = dots
        usb[1 + 44] = r; usb[1 + 45] = g; usb[1 + 46] = b
        _ = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x02, usb, 63)
    }

    private static let crcTable: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i: UInt32 in 0..<256 {
            var c = i
            for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB88320 : c >> 1 }
            t[Int(i)] = c
        }
        return t
    }()

    private static func crc32le(_ bytes: [UInt8]) -> UInt32 {  // без финального xor — даёт вызывающий
        var crc: UInt32 = 0xFFFFFFFF
        for b in bytes { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc
    }

    // MARK: - меню-бар

    private func updateTitle(_ bat: (pct: Int, charging: Bool)?) {
        guard let button = item.button else { return }
        if let bat = bat {
            let icon = bat.charging ? "⚡" : "🎮"
            let title = "\(icon) \(bat.pct)%"
            let color: NSColor = bat.pct <= 20 ? .systemRed : .labelColor
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            ])
            let stateWord = L(bat.charging ? "charging" : "discharging")
            statusLine?.title = String(format: L("status_format"), bat.pct, stateWord)
            NSLog("ds5batt: title = \(title) (\(stateWord))")
        } else {
            button.attributedTitle = NSAttributedString(
                string: "🎮 —", attributes: [.foregroundColor: NSColor.secondaryLabelColor])
            statusLine?.title = L("not_connected")
            NSLog("ds5batt: нет контроллера")
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.prohibited)
app.run()
