import Foundation

/// Чистая логика жеста «двойное нажатие правого Shift» — конечный автомат без AppKit/NSEvent,
/// поэтому проверяется на искусственных событиях со временем (tests/run.sh, context-check --shift).
///
/// Правила:
/// - правый Shift нажат и отпущен, затем снова нажат не позже `tapWindow` (~350 мс) после первого отпускания;
/// - каждое нажатие короткое: удерживание дольше `maxHold` (~300 мс) не считается;
/// - срабатывание — на отпускании второго нажатия (так ловится и набор во время второго удержания);
/// - любая другая клавиша (keyDown), другой модификатор, левый Shift или оба Shift сразу — сброс;
/// - один раз на двойное нажатие: нажатие, начатое не позже `tapWindow` после срабатывания,
///   пропускается целиком (тройное нажатие не даёт второго срабатывания сразу).
struct DoubleTapDetector: Sendable {
    enum Input: Sendable, Equatable {
        /// Правый Shift нажат (down: true) / отпущен (false), других модификаторов при этом нет.
        case rightShift(down: Bool)
        /// Всё остальное: keyDown любой клавиши, левый Shift, оба Shift, ⌘/⌃/⌥/fn/Caps Lock,
        /// правый Shift при зажатом другом модификаторе.
        case other
    }

    enum State: Sendable, Equatable {
        case idle
        case firstDown(at: TimeInterval)
        case firstUp(at: TimeInterval)
        case secondDown(at: TimeInterval)
        /// Нажатие сразу после срабатывания (тройное) или испорченное — ждём отпускания.
        case ignoring
    }

    /// Максимум между первым отпусканием и вторым нажатием.
    var tapWindow: TimeInterval = 0.35
    /// Максимальная длительность каждого нажатия.
    var maxHold: TimeInterval = 0.30

    private(set) var state: State = .idle
    private var lastFiredAt: TimeInterval = -.greatestFiniteMagnitude

    init(tapWindow: TimeInterval = 0.35, maxHold: TimeInterval = 0.30) {
        self.tapWindow = tapWindow
        self.maxHold = maxHold
    }

    mutating func reset() { state = .idle }

    /// Подать событие; `time` — секунды (монотонные, как NSEvent.timestamp).
    /// Возвращает true, если в этот момент жест сработал.
    @discardableResult
    mutating func feed(_ input: Input, at time: TimeInterval) -> Bool {
        switch input {
        case .other:
            // Набор/другие клавиши: если правый Shift сейчас зажат — дожидаемся его отпускания впустую.
            switch state {
            case .firstDown, .secondDown, .ignoring: state = .ignoring
            case .idle, .firstUp: state = .idle
            }
            return false

        case .rightShift(down: true):
            switch state {
            case .idle:
                state = (time - lastFiredAt <= tapWindow) ? .ignoring : .firstDown(at: time)
            case .firstUp(let upAt):
                // опоздали — это уже новое первое нажатие
                state = (time - upAt <= tapWindow) ? .secondDown(at: time) : .firstDown(at: time)
            case .firstDown, .secondDown, .ignoring:
                break  // повтор события без отпускания
            }
            return false

        case .rightShift(down: false):
            switch state {
            case .firstDown(let downAt):
                state = (time - downAt <= maxHold) ? .firstUp(at: time) : .idle
                return false
            case .secondDown(let downAt):
                state = .idle
                guard time - downAt <= maxHold else { return false }
                lastFiredAt = time
                return true
            case .idle, .firstUp, .ignoring:
                state = .idle
                return false
            }
        }
    }
}
