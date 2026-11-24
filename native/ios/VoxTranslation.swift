// Traducteur du téléphone sur iPhone : la traduction d'Apple (cadre
// Translation, iOS 18 ou plus), sur l'appareil, gratuite et sans limite.
// Canal « voxliso/translation » : isSupported, status, translate, prepare.
//
// tool/setup.dart ajoute ce code à la fin de ios/Runner/AppDelegate.swift
// (un fichier à part devrait être déclaré dans le projet Xcode) et
// l'enregistre à côté de GeneratedPluginRegistrant.

#if canImport(Translation)
import Translation
import SwiftUI
#endif

class VoxTranslationPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "voxliso/translation", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(VoxTranslationPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    #if canImport(Translation)
    if #available(iOS 18.0, *) {
      Task { @MainActor in VoxTranslationHost.shared.handle(call, result: result) }
      return
    }
    #endif
    if call.method == "isSupported" {
      result(false)
    } else {
      result(nil)
    }
  }
}

#if canImport(Translation)
/// Les sessions de traduction ne s'obtiennent que par une vue SwiftUI
/// (`translationTask`) : une vue invisible de 1 point, ajoutée à la fenêtre,
/// reçoit une session à chaque demande et exécute les demandes une par une.
@available(iOS 18.0, *)
@MainActor
final class VoxTranslationModel: ObservableObject {
  @Published var configuration: TranslationSession.Configuration?

  struct Job {
    let from: Locale.Language
    let to: Locale.Language
    let work: (TranslationSession) async throws -> Any?
    let done: (Any?) -> Void
  }

  private var jobs: [(id: Int, job: Job)] = []
  private var nextId = 0
  private var running = false
  /// Demande en attente de sa session.
  private var current: (id: Int, job: Job)?

  func enqueue(_ job: Job) {
    jobs.append((nextId, job))
    nextId += 1
    if !running { next() }
  }

  private func next() {
    guard !jobs.isEmpty else {
      running = false
      return
    }
    running = true
    let item = jobs.removeFirst()
    current = item
    if var c = configuration, c.source == item.job.from, c.target == item.job.to {
      c.invalidate()
      configuration = c
    } else {
      configuration = TranslationSession.Configuration(source: item.job.from, target: item.job.to)
    }
    // Session jamais reçue (vue absente…) : on abandonne au bout de 8 s.
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
      guard let self, let cur = self.current, cur.id == item.id else { return }
      self.current = nil
      cur.job.done(nil)
      self.next()
    }
  }

  func run(_ session: TranslationSession) async {
    guard let job = current?.job else { return }
    current = nil
    var value: Any? = nil
    do {
      value = try await job.work(session)
    } catch {
      value = nil
    }
    job.done(value)
    DispatchQueue.main.async { [weak self] in self?.next() }
  }
}

@available(iOS 18.0, *)
struct VoxTranslationView: View {
  @ObservedObject var model: VoxTranslationModel

  var body: some View {
    Color.clear
      .frame(width: 1, height: 1)
      .translationTask(model.configuration) { session in
        await model.run(session)
      }
  }
}

@available(iOS 18.0, *)
@MainActor
final class VoxTranslationHost {
  static let shared = VoxTranslationHost()

  private let model = VoxTranslationModel()
  private var hosting: UIHostingController<VoxTranslationView>?

  private func keyWindow() -> UIWindow? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
      ?? scenes.flatMap { $0.windows }.first
  }

  /// Ajoute la vue invisible au contrôleur principal (une seule fois).
  private func ensureHost() {
    if let h = hosting, h.view.window != nil { return }
    guard let root = keyWindow()?.rootViewController else { return }
    let h = UIHostingController(rootView: VoxTranslationView(model: model))
    h.view.backgroundColor = .clear
    h.view.isUserInteractionEnabled = false
    h.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    root.addChild(h)
    root.view.addSubview(h.view)
    h.didMove(toParent: root)
    hosting = h
  }

  private static func language(_ code: Any?) -> Locale.Language {
    Locale.Language(identifier: (code as? String) ?? "en")
  }

  private static func statusName(_ s: LanguageAvailability.Status) -> String {
    switch s {
    case .installed: return "installed"
    case .supported: return "supported"
    default: return "unsupported"
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let from = Self.language(args["from"])
    let to = Self.language(args["to"])
    switch call.method {
    case "isSupported":
      result(true)

    case "status":
      Task {
        let s = await LanguageAvailability().status(from: from, to: to)
        result(Self.statusName(s))
      }

    case "translate":
      let texts = args["texts"] as? [String] ?? []
      Task {
        // Langue pas encore téléchargée : pas de fenêtre pendant la lecture.
        let s = await LanguageAvailability().status(from: from, to: to)
        guard s == .installed, !texts.isEmpty else {
          result(nil)
          return
        }
        self.ensureHost()
        self.model.enqueue(
          VoxTranslationModel.Job(
            from: from, to: to,
            work: { session in
              let requests = texts.enumerated().map {
                TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
              }
              let responses = try await session.translations(from: requests)
              var out = Array(repeating: "", count: texts.count)
              for r in responses {
                if let id = r.clientIdentifier, let i = Int(id), i < out.count {
                  out[i] = r.targetText
                }
              }
              return out
            },
            done: { value in result(value) }))
      }

    case "prepare":
      // Fenêtre d'iOS qui propose de télécharger les langues.
      ensureHost()
      model.enqueue(
        VoxTranslationModel.Job(
          from: from, to: to,
          work: { session in
            try await session.prepareTranslation()
            return true
          },
          done: { value in result((value as? Bool) ?? false) }))

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
#endif
