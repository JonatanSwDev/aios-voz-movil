// El motor de audio de la app de la voz del AIOS (2026-11-08, plan brainstorms/2026-11-08-plan-app-iphone-brigada.md).
//
// Graba y reproduce a la vez en un solo AVAudioEngine, con la unidad de voz de iOS (cancelación de eco, ruido y
// ganancia, la de las llamadas) si está encendida en los ajustes, y habla con la escucha del PC en nativo, sin pasar por
// el JavaScript: con la pantalla bloqueada iOS puede parar el JavaScript, pero no una app con audio en marcha y el modo de
// fondo «audio».
//
// El protocolo es el de mods/aios-voz/escucha/movil.py, con la ficha en la cabecera X-Ficha:
//   POST /audio?rate=16000   PCM int16 mono a 16 kHz, un envío cada 250 ms
//   GET  /salida             {"gen": N, "ganancia": g, "frases": [{"n", "wav", "gen"}]}, cada 400 ms
//   GET  /wav/frase-N.wav?g= el wav de Piper (22.050 Hz, mono), con la ganancia aplicada en el PC
// Si la generación sube («calla», «para»), se corta lo que suena y se tira la cola, como hacía el prototipo.
//
// Todo el estado vive en una cola serie (`cola`). El «tap» del micro corre en su propio hilo, con su conversor capturado,
// y solo le pasa datos. El estado y el registro que lee el JavaScript van además en copias bajo un cerrojo, para que la
// pantalla no espere a la cola. Auditado antes de compilar (centro-audit, 2026-11-08): lo corregido, en el diario.
//
// El registro (Jonatan, 8-nov: «logs a mansalva» para ver qué pasa al copiarlo): cada arranque y reanudación con la sesión
// y el formato real del micro; los primeros envíos de cada arranque uno a uno, los que fallan o tardan siempre, y cada 5 s
// un resumen de lo captado, enviado y tirado, con la latencia y el nivel; cada frase del PC (bajada, encolada, sonada);
// los tonos, los cambios de estado con su motivo y los avisos de iOS con sus valores. Nunca la ficha; de la dirección,
// solo su primera parte.

import AVFoundation
import Foundation
import UIKit

/// Una marca que el bloque de entrada del conversor puede cambiar aunque el SDK lo declare concurrente.
private final class Bandera {
  var hecha = false
}

final class MotorVoz {
  struct Ajustes {
    let base: URL
    let ficha: String
    let microDeLosCascos: Bool
    let ganancia: Double
    let unidadDeVoz: Bool
  }

  /// Los contadores de un intervalo del resumen; se ponen a cero tras cada resumen.
  private struct Cuenta {
    var buffers = 0
    var bytesCaptados = 0
    var bytesTirados = 0
    var dbSuma = 0.0
    var dbMax = -200.0
    var dbN = 0
    var enviosOk = 0
    var enviosMal = 0
    var bytesEnviados = 0
    var latSuma = 0
    var latMax = 0
    var sondeosOk = 0
    var sondeosMal = 0
  }

  // Lo que el módulo de Expo le pasa al JavaScript.
  var alEstado: ((String) -> Void)?
  var alRegistro: ((String) -> Void)?
  var alNivel: ((Double) -> Void)?

  private var estadoActual = "parado"
  private var lineas: [String] = []
  private let maxLineas = 6000
  private let cerrojo = NSLock()
  private var estadoCopia = "parado"
  private var lineasCopia: [String] = []
  private let reloj: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()

  private let cola = DispatchQueue(label: "aios.voz.motor")
  private var motor = AVAudioEngine()
  private var voz = AVAudioPlayerNode()
  private var pitidos = AVAudioPlayerNode()
  private var montado = false
  private let formatoEnvio = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
  private let formatoVoz = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!

  private var ajustes: Ajustes?
  private var enMarcha = false
  private var sesion = 0 // sube al empezar y al parar: un permiso que llega tarde no arranca nada
  private var sesionRed: URLSession
  private var relojEnvio: DispatchSourceTimer?
  private var relojSondeo: DispatchSourceTimer?
  private var relojResumen: DispatchSourceTimer?

  // La captura que espera su envío. Como mucho 3 s: lo que llega tarde no es un dictado que se envía.
  private var pendiente = Data()
  private let maxPendiente = 16000 * 2 * 3
  private var enviando = false
  private var cuenta = Cuenta()
  private var enviosDetallados = 0 // los primeros envíos tras cada arranque se anotan uno a uno
  private var primerBuffer = true // el primer buffer del micro tras cada arranque se anota con su formato

  // Lo que dice el PC.
  private var sondeando = false
  private var gen = -1
  private var ultimaN = 0
  private var primeraSalida = true
  private var colaFrases: [String] = []
  private var ganancia = 2.5
  private var bajada: URLSessionDataTask?
  private var corte = 0 // sube en cada corte: lo que se estaba bajando antes no se toca
  private var ultimoSondeoMal = Date.distantPast

  // El contacto con el PC, para el pitido de «sin PC» y el de vuelta. Un 403 cuenta como contacto: el PC está, lo que
  // falla es la ficha, y eso se dice con su estado, no con el pitido de «sin PC».
  private var ultimoContacto = Date()
  private var sinPC = false
  private let plazoSinPC: TimeInterval = 10
  // El último tic del sondeo: si entre dos tics pasan más de 3 s, la app estuvo suspendida (visto el 8-nov: con el motor
  // parado iOS la suspende) y el silencio no es del PC: no se avisa de «sin PC» por eso.
  private var ultimoTic = Date()

  private var ultimoNivel = Date.distantPast
  private var reintentos = 0
  // Los rearranques del último minuto: más de seis es un bucle (un cambio de configuración que se dispara solo).
  private var rearranques: [Date] = []
  private var ultimo403 = Date.distantPast
  private var observadores: [NSObjectProtocol] = []
  // Los avisos de cambio de configuración llegan en ráfaga: se agrupan y se reanuda una vez.
  private var reanudacionPendiente = false

  init() {
    let c = URLSessionConfiguration.default
    c.timeoutIntervalForRequest = 5
    c.timeoutIntervalForResource = 10
    c.waitsForConnectivity = false
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.httpMaximumConnectionsPerHost = 4
    sesionRed = URLSession(configuration: c)
    let centro = NotificationCenter.default
    observadores.append(centro.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) {
      [weak self] n in
      self?.interrupcion(n)
    })
    observadores.append(centro.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) {
      [weak self] n in
      self?.cambioDeRuta(n)
    })
    observadores.append(centro.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: nil) {
      [weak self] _ in
      guard let self = self else { return }
      self.cola.async { self.anotar("iOS: se perdieron los servicios de audio") }
    })
    observadores.append(centro.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) {
      [weak self] _ in
      guard let self = self else { return }
      self.cola.async {
        self.anotar("iOS: los servicios de audio se reiniciaron")
        self.rearrancar("los servicios de audio de iOS se reiniciaron")
      }
    })
    observadores.append(centro.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) {
      [weak self] n in
      guard let self = self else { return }
      // Un cambio de configuración para el motor. Visto en el aparato el 8-nov: con la unidad de voz y el micro de los
      // cascos, iOS lo avisa justo después de cada arranque (la sesión pasa a 16 kHz), sin que cambie la ruta. Montar un
      // motor nuevo lo volvía a provocar, en bucle: se reanuda el MISMO motor, con el micro enganchado de nuevo.
      self.cola.async {
        guard let quien = n.object as? AVAudioEngine, quien === self.motor else { return }
        self.anotar("iOS: aviso de cambio de configuración del motor · \(self.estadoAudio())")
        self.programarReanudar("cambió la configuración del audio")
      }
    })
    // Si una interrupción no avisa de que acabó (pasa con mixWithOthers), al volver la app delante se reanuda.
    observadores.append(centro.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) {
      [weak self] _ in
      guard let self = self else { return }
      self.cola.async {
        self.anotar("iOS: la app pasa delante · \(self.estadoAudio())")
        if self.enMarcha && !self.motor.isRunning { self.programarReanudar("la app vuelve delante") }
      }
    })
    observadores.append(centro.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) {
      [weak self] _ in
      guard let self = self else { return }
      self.cola.async { self.anotar("iOS: la app pasa a segundo plano · \(self.estadoAudio())") }
    })
  }

  deinit {
    observadores.forEach { NotificationCenter.default.removeObserver($0) }
  }

  // MARK: - Empezar y parar

  func empezar(_ a: Ajustes, listo: @escaping (String?) -> Void) {
    cola.async {
      self.sesion += 1
      let estaSesion = self.sesion
      AVAudioSession.sharedInstance().requestRecordPermission { [weak self] permitido in
        guard let self = self else { return }
        self.cola.async { self.arrancar(a, permitido, estaSesion, listo) }
      }
    }
  }

  private func arrancar(_ a: Ajustes, _ permitido: Bool, _ estaSesion: Int, _ listo: @escaping (String?) -> Void) {
    guard estaSesion == sesion else {
      listo("parado antes de empezar")
      return
    }
    guard permitido else {
      fijarEstado("sin permiso de micro", "iOS no da el micro")
      listo("sin permiso de micro: actívalo en Ajustes")
      return
    }
    if enMarcha { pararDentro() }
    ajustes = a
    ganancia = a.ganancia // hasta que la salida del PC diga la suya
    gen = -1
    ultimaN = 0
    primeraSalida = true
    colaFrases = []
    pendiente = Data()
    cuenta = Cuenta()
    ultimoContacto = Date()
    ultimoTic = Date()
    sinPC = false
    reintentos = 0
    rearranques = []
    anotar("empieza: \(a.microDeLosCascos ? "micro de los cascos" : "micro del iPhone"), unidad de voz \(a.unidadDeVoz ? "encendida" : "apagada"), PC \(hostVisible(a.base))")
    do {
      try configurarSesion(a)
      try montarMotor()
    } catch {
      desmontarMotor()
      anotar("no arranca el audio: \(error.localizedDescription)")
      fijarEstado("error de audio", "no arranca")
      listo("no arranca el audio: \(error.localizedDescription)")
      return
    }
    enMarcha = true
    arrancarRelojes()
    fijarEstado("conectando", "empieza")
    listo(nil)
  }

  func parar() {
    cola.async {
      self.sesion += 1
      self.pararDentro()
    }
  }

  private func pararDentro() {
    let estaba = enMarcha || montado
    if estaba { resumir() }
    enMarcha = false
    relojEnvio?.cancel()
    relojSondeo?.cancel()
    relojResumen?.cancel()
    relojEnvio = nil
    relojSondeo = nil
    relojResumen = nil
    bajada?.cancel()
    bajada = nil
    desmontarMotor()
    colaFrases = []
    pendiente = Data()
    corte += 1
    guard estaba else { return }
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    anotar("para")
    fijarEstado("parado", "Parar")
  }

  /// Para la pantalla: copias bajo el cerrojo, sin esperar a la cola.
  func registro() -> [String] {
    cerrojo.lock()
    defer { cerrojo.unlock() }
    return lineasCopia
  }

  func estado() -> String {
    cerrojo.lock()
    defer { cerrojo.unlock() }
    return estadoCopia
  }

  // MARK: - La sesión y el motor

  private func configurarSesion(_ a: Ajustes) throws {
    let s = AVAudioSession.sharedInstance()
    // mixWithOthers: la música del móvil sigue. Con el micro de los cascos (manos libres) la música baja a calidad de
    // teléfono mientras la app está en marcha: límite conocido de Bluetooth clásico (voz.md 6.1).
    var opciones: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker]
    if a.microDeLosCascos {
      opciones.insert(.allowBluetooth)
    } else {
      opciones.insert(.allowBluetoothA2DP)
    }
    try s.setCategory(.playAndRecord, mode: .default, options: opciones)
    try s.setActive(true)
    anotar("sesión activa · \(describirSesion())")
  }

  private func montarMotor() throws {
    motor = AVAudioEngine()
    voz = AVAudioPlayerNode()
    pitidos = AVAudioPlayerNode()
    montado = true
    let entrada = motor.inputNode
    // La unidad de voz de Apple: cancela el eco de lo que suena, quita ruido y ajusta la ganancia. Se enciende antes de
    // leer el formato de la entrada y antes de arrancar. Con los cascos se puede apagar (8-nov: con la unidad de voz
    // encima del perfil de manos libres, buena parte de lo dicho llegaba al PC sin que Whisper sacara texto).
    if ajustes?.unidadDeVoz ?? true {
      try entrada.setVoiceProcessingEnabled(true)
      if #available(iOS 17.0, *) {
        entrada.voiceProcessingOtherAudioDuckingConfiguration =
          AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
      }
    }
    let formatoEntrada = entrada.outputFormat(forBus: 0)
    anotar("micro: unidad de voz \(entrada.isVoiceProcessingEnabled ? "encendida" : "apagada"), formato \(describirFormato(formatoEntrada))")
    guard formatoEntrada.sampleRate > 0, formatoEntrada.channelCount > 0 else {
      throw NSError(domain: "MotorVoz", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "el micro no da formato (\(estadoAudio()))"])
    }
    guard let conv = AVAudioConverter(from: formatoEntrada, to: formatoEnvio) else {
      throw NSError(domain: "MotorVoz", code: 2, userInfo: [NSLocalizedDescriptionKey: "no hay conversor a 16 kHz"])
    }
    // El conversor va capturado en el tap: el hilo del micro nunca lee una propiedad que la cola cambia.
    entrada.installTap(onBus: 0, bufferSize: 4096, format: formatoEntrada) { [weak self] buffer, _ in
      self?.capturado(buffer, conv)
    }
    motor.attach(voz)
    motor.attach(pitidos)
    motor.connect(voz, to: motor.mainMixerNode, format: formatoVoz)
    motor.connect(pitidos, to: motor.mainMixerNode, format: formatoVoz)
    motor.prepare()
    try motor.start()
    voz.play()
    pitidos.play()
    enviosDetallados = 0
    primerBuffer = true
    anotar("motor en marcha: micro a \(Int(formatoEntrada.sampleRate)) Hz, \(formatoEntrada.channelCount) canal(es) · salida \(describirFormato(motor.outputNode.outputFormat(forBus: 0)))")
  }

  private func desmontarMotor() {
    guard montado else { return }
    montado = false
    motor.inputNode.removeTap(onBus: 0)
    voz.stop()
    pitidos.stop()
    motor.stop()
  }

  /// Tras perder los servicios de audio, o si reanudar no basta: el motor se monta de nuevo, sin perder la conexión con
  /// el PC. Si iOS no le deja arrancar, lo reintenta cada 2 s hasta diez veces.
  private func rearrancar(_ motivo: String) {
    guard enMarcha, let a = ajustes else { return }
    let ahora = Date()
    rearranques = rearranques.filter { ahora.timeIntervalSince($0) < 60 } + [ahora]
    if rearranques.count > 6 && motivo != "reintento" {
      desmontarMotor()
      anotar("demasiados rearranques en un minuto (\(motivo)): lo dejo parado; pulsa Parar y Empezar")
      fijarEstado("error de audio", "demasiados rearranques")
      return
    }
    anotar("rearranco (motor nuevo): \(motivo)")
    bajada?.cancel()
    bajada = nil
    desmontarMotor()
    corte += 1
    colaFrases = []
    do {
      try configurarSesion(a)
      try montarMotor()
      reintentos = 0
      fijarEstado(sinPC ? "sin PC" : "conectado", "motor nuevo")
    } catch {
      desmontarMotor()
      reintentos += 1
      anotar("no rearranca (\(reintentos)): \(error.localizedDescription)")
      fijarEstado("error de audio", "no rearranca")
      if reintentos <= 10 {
        cola.asyncAfter(deadline: .now() + 2) { [weak self] in self?.rearrancar("reintento") }
      }
    }
  }

  /// Agrupa los avisos que llegan seguidos: medio segundo después, una sola reanudación.
  private func programarReanudar(_ motivo: String) {
    guard enMarcha, !reanudacionPendiente else { return }
    reanudacionPendiente = true
    cola.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self = self else { return }
      self.reanudacionPendiente = false
      self.reanudarMotor(motivo)
    }
  }

  /// Vuelve a poner en marcha el MISMO motor (la unidad de voz ya encendida no se toca): el micro se engancha de nuevo con
  /// el formato que tenga ahora y el motor arranca. Solo si el motor no está montado, o no vuelve tras diez intentos, se
  /// monta uno nuevo (`rearrancar`).
  private func reanudarMotor(_ motivo: String) {
    guard enMarcha else { return }
    guard montado else {
      rearrancar(motivo)
      return
    }
    if motor.isRunning {
      anotar("no hace falta reanudar (\(motivo)): el motor ya corre")
      return
    }
    if motivo != "reintento" {
      let ahora = Date()
      rearranques = rearranques.filter { ahora.timeIntervalSince($0) < 60 } + [ahora]
      if rearranques.count > 8 {
        desmontarMotor()
        anotar("demasiadas reanudaciones en un minuto (\(motivo)): lo dejo parado; pulsa Parar y Empezar")
        fijarEstado("error de audio", "demasiadas reanudaciones")
        return
      }
    }
    anotar("reanudo el motor: \(motivo) · \(estadoAudio())")
    let entrada = motor.inputNode
    entrada.removeTap(onBus: 0)
    let formato = entrada.outputFormat(forBus: 0)
    guard formato.sampleRate > 0, formato.channelCount > 0,
          let conv = AVAudioConverter(from: formato, to: formatoEnvio) else {
      reintentos += 1
      anotar("el micro aún no da formato (\(reintentos)): \(describirFormato(formato)); reintento en 1 s")
      if reintentos <= 10 {
        cola.asyncAfter(deadline: .now() + 1) { [weak self] in self?.reanudarMotor("reintento") }
      } else {
        rearrancar("el micro no vuelve")
      }
      return
    }
    entrada.installTap(onBus: 0, bufferSize: 4096, format: formato) { [weak self] buffer, _ in
      self?.capturado(buffer, conv)
    }
    do {
      motor.prepare()
      try motor.start()
      voz.play()
      pitidos.play()
      reintentos = 0
      enviosDetallados = 0
      primerBuffer = true
      anotar("motor reanudado: micro \(describirFormato(formato)), unidad de voz \(entrada.isVoiceProcessingEnabled ? "encendida" : "apagada") · \(describirSesion())")
      fijarEstado(sinPC ? "sin PC" : "conectando", "motor reanudado")
    } catch {
      reintentos += 1
      anotar("no reanuda (\(reintentos)): \(error.localizedDescription)")
      fijarEstado("error de audio", "no reanuda")
      if reintentos <= 10 {
        cola.asyncAfter(deadline: .now() + 2) { [weak self] in self?.reanudarMotor("reintento") }
      } else {
        rearrancar("no reanuda")
      }
    }
  }

  // MARK: - Lo que dice iOS

  private func interrupcion(_ n: Notification) {
    guard let valor = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let tipo = AVAudioSession.InterruptionType(rawValue: valor) else { return }
    let opciones = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
    cola.async {
      switch tipo {
      case .began:
        self.anotar("iOS: interrupción, empieza · \(self.estadoAudio())")
        self.fijarEstado("interrumpido", "interrupción de iOS")
      case .ended:
        let reanudar = AVAudioSession.InterruptionOptions(rawValue: opciones).contains(.shouldResume)
        self.anotar("iOS: interrupción, acaba (iOS \(reanudar ? "pide" : "no pide") reanudar) · \(self.estadoAudio())")
        self.programarReanudar("fin de la interrupción")
      @unknown default:
        self.anotar("iOS: interrupción de tipo desconocido (\(valor))")
      }
    }
  }

  private func cambioDeRuta(_ n: Notification) {
    let valor = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
    let anterior = n.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
    let antes = anterior.map { describirRuta($0) } ?? "?"
    cola.async {
      self.anotar("iOS: cambio de ruta (\(self.nombreMotivoRuta(valor))) · antes \(antes) · ahora \(self.describirRuta(AVAudioSession.sharedInstance().currentRoute)) · motor \(self.motor.isRunning ? "en marcha" : "parado")")
    }
  }

  private func nombreMotivoRuta(_ v: UInt) -> String {
    guard let motivo = AVAudioSession.RouteChangeReason(rawValue: v) else { return "desconocido \(v)" }
    switch motivo {
    case .newDeviceAvailable: return "aparato nuevo"
    case .oldDeviceUnavailable: return "se fue un aparato"
    case .categoryChange: return "cambio de categoría"
    case .override: return "anulación"
    case .wakeFromSleep: return "vuelta del reposo"
    case .noSuitableRouteForCategory: return "sin ruta para la categoría"
    case .routeConfigurationChange: return "cambio de configuración de la ruta"
    default: return "desconocido \(v)"
    }
  }

  // MARK: - La captura

  /// En el hilo del micro: convierte a 16 kHz int16 mono y se lo pasa a la cola.
  private func capturado(_ buffer: AVAudioPCMBuffer, _ conv: AVAudioConverter) {
    guard buffer.frameLength > 0 else { return }
    let formato = buffer.format
    let tramasEntrada = Int(buffer.frameLength)
    let capacidad = AVAudioFrameCount(Double(buffer.frameLength) * formatoEnvio.sampleRate / buffer.format.sampleRate) + 64
    guard let salida = AVAudioPCMBuffer(pcmFormat: formatoEnvio, frameCapacity: capacidad) else { return }
    let entregado = Bandera()
    var error: NSError?
    let estado = conv.convert(to: salida, error: &error) { _, estadoEntrada in
      if entregado.hecha {
        estadoEntrada.pointee = .noDataNow
        return nil
      }
      entregado.hecha = true
      estadoEntrada.pointee = .haveData
      return buffer
    }
    guard estado != .error, error == nil, salida.frameLength > 0, let canal = salida.int16ChannelData else {
      let motivo = error?.localizedDescription ?? "estado \(estado.rawValue), \(salida.frameLength) tramas"
      cola.async { self.anotar("el conversor del micro falla: \(motivo)") }
      return
    }
    let n = Int(salida.frameLength)
    let datos = Data(bytes: canal[0], count: n * 2)
    var suma = 0.0
    for i in 0..<n {
      let v = Double(canal[0][i]) / 32768.0
      suma += v * v
    }
    let db = 20 * log10(max(sqrt(suma / Double(n)), 0.000_01))
    cola.async {
      guard self.enMarcha else { return }
      if self.primerBuffer {
        self.primerBuffer = false
        self.anotar("primer buffer del micro: \(tramasEntrada) tramas en \(self.describirFormato(formato)) → \(n) tramas a 16 kHz int16, \(Int(db)) dB")
      }
      self.cuenta.buffers += 1
      self.cuenta.bytesCaptados += datos.count
      self.cuenta.dbSuma += db
      self.cuenta.dbN += 1
      self.cuenta.dbMax = max(self.cuenta.dbMax, db)
      self.pendiente.append(datos)
      if self.pendiente.count > self.maxPendiente {
        let sobra = self.pendiente.count - self.maxPendiente
        self.pendiente.removeFirst(sobra)
        self.cuenta.bytesTirados += sobra
      }
      let ahora = Date()
      if ahora.timeIntervalSince(self.ultimoNivel) >= 0.5 {
        self.ultimoNivel = ahora
        self.alNivel?(db)
      }
    }
  }

  // MARK: - La red

  private func arrancarRelojes() {
    let envio = DispatchSource.makeTimerSource(queue: cola)
    envio.schedule(deadline: .now() + 0.25, repeating: 0.25)
    envio.setEventHandler { [weak self] in self?.enviar() }
    envio.resume()
    relojEnvio = envio
    let sondeo = DispatchSource.makeTimerSource(queue: cola)
    sondeo.schedule(deadline: .now() + 0.1, repeating: 0.4)
    sondeo.setEventHandler { [weak self] in
      self?.sondear()
      self?.vigilarContacto()
    }
    sondeo.resume()
    relojSondeo = sondeo
    let resumen = DispatchSource.makeTimerSource(queue: cola)
    resumen.schedule(deadline: .now() + 5, repeating: 5)
    resumen.setEventHandler { [weak self] in self?.resumir() }
    resumen.resume()
    relojResumen = resumen
  }

  /// Cada 5 s: lo captado, lo enviado y lo tirado, la latencia, el nivel y el motor.
  private func resumir() {
    let c = cuenta
    cuenta = Cuenta()
    let nivel = c.dbN > 0 ? "\(Int(c.dbSuma / Double(c.dbN))) dB medio, \(Int(c.dbMax)) dB máximo" : "sin audio del micro"
    let latencia = c.enviosOk > 0 ? "\(c.latSuma / c.enviosOk) ms medio, \(c.latMax) ms máximo" : "-"
    anotar("resumen 5 s · micro: \(c.buffers) buffers, \(c.bytesCaptados) B, \(nivel) · envíos: \(c.enviosOk) bien, \(c.enviosMal) mal, \(c.bytesEnviados) B, latencia \(latencia) · tirado \(c.bytesTirados) B, pendiente \(pendiente.count) B · sondeos: \(c.sondeosOk) bien, \(c.sondeosMal) mal · motor \(motor.isRunning ? "en marcha" : "parado"), estado \(estadoActual)")
  }

  private func peticion(_ ruta: String, _ consulta: [URLQueryItem] = []) -> URLRequest? {
    guard let a = ajustes, var c = URLComponents(url: a.base, resolvingAgainstBaseURL: false) else { return nil }
    let base = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
    c.path = base + ruta
    c.queryItems = consulta.isEmpty ? nil : consulta
    guard let url = c.url else { return nil }
    var r = URLRequest(url: url)
    r.setValue(a.ficha, forHTTPHeaderField: "X-Ficha")
    return r
  }

  private func enviar() {
    guard enMarcha, !enviando, !pendiente.isEmpty, var r = peticion("/audio", [URLQueryItem(name: "rate", value: "16000")]) else {
      return
    }
    let cuerpo = pendiente
    pendiente = Data()
    enviando = true
    r.httpMethod = "POST"
    r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    let inicio = Date()
    sesionRed.uploadTask(with: r, from: cuerpo) { [weak self] _, respuesta, error in
      guard let self = self else { return }
      self.cola.async {
        self.enviando = false
        let ms = Int(Date().timeIntervalSince(inicio) * 1000)
        let codigo = (respuesta as? HTTPURLResponse)?.statusCode ?? 0
        let bien = error == nil && codigo == 204
        if bien {
          self.cuenta.enviosOk += 1
          self.cuenta.bytesEnviados += cuerpo.count
          self.cuenta.latSuma += ms
          self.cuenta.latMax = max(self.cuenta.latMax, ms)
        } else {
          self.cuenta.enviosMal += 1
        }
        if self.enviosDetallados < 12 || !bien || ms > 800 {
          self.enviosDetallados += 1
          self.anotar("→ audio \(cuerpo.count) B a 16000 Hz: \(codigo == 0 ? "sin respuesta" : String(codigo)) en \(ms) ms\(error.map { " · \($0.localizedDescription)" } ?? "")")
        }
        guard self.enMarcha else { return }
        if bien {
          self.contacto()
          return
        }
        if codigo == 403 {
          self.avisar403()
          return
        }
        // Lo no enviado vuelve delante, sin pasar de 3 s.
        var junto = cuerpo
        junto.append(self.pendiente)
        if junto.count > self.maxPendiente {
          let sobra = junto.count - self.maxPendiente
          junto.removeFirst(sobra)
          self.cuenta.bytesTirados += sobra
        }
        self.pendiente = junto
      }
    }.resume()
  }

  private struct Frase: Decodable {
    let n: Int
    let wav: String
    let gen: Int
  }

  private struct Salida: Decodable {
    let gen: Int
    let ganancia: Double?
    let frases: [Frase]
  }

  private func sondear() {
    guard enMarcha, !sondeando, let r = peticion("/salida") else { return }
    sondeando = true
    sesionRed.dataTask(with: r) { [weak self] datos, respuesta, error in
      guard let self = self else { return }
      self.cola.async {
        self.sondeando = false
        guard self.enMarcha else { return }
        let codigo = (respuesta as? HTTPURLResponse)?.statusCode ?? 0
        if codigo == 403 {
          self.cuenta.sondeosMal += 1
          self.avisar403()
          return
        }
        guard error == nil, codigo == 200, let datos = datos,
              let s = try? JSONDecoder().decode(Salida.self, from: datos) else {
          self.cuenta.sondeosMal += 1
          let ahora = Date()
          if ahora.timeIntervalSince(self.ultimoSondeoMal) > 10 {
            self.ultimoSondeoMal = ahora
            self.anotar("← salida: \(codigo == 0 ? "sin respuesta" : String(codigo))\(error.map { " · \($0.localizedDescription)" } ?? "")")
          }
          return
        }
        self.cuenta.sondeosOk += 1
        self.contacto()
        self.recibir(s)
      }
    }.resume()
  }

  private func recibir(_ s: Salida) {
    ganancia = s.ganancia ?? ganancia
    if primeraSalida {
      // Lo que el PC ya tenía antes de empezar no se dice.
      primeraSalida = false
      gen = s.gen
      ultimaN = s.frases.map { $0.n }.max() ?? 0
      anotar("← salida inicial: generación \(s.gen), \(s.frases.count) frase(s) que no se dicen, ganancia \(ganancia)")
      return
    }
    if s.gen != gen {
      anotar("← corte (generación \(gen) → \(s.gen)): se calla lo que suena y se tira la cola (\(colaFrases.count) pendiente(s))")
      cortar()
      gen = s.gen
      // Al cambiar de generación lo que haya en la salida es nuevo: se empieza por la primera.
      ultimaN = (s.frases.map { $0.n }.min() ?? 1) - 1
    }
    let nuevas = s.frases.filter { $0.gen == s.gen && $0.n > ultimaN }.sorted { $0.n < $1.n }
    guard let ultima = nuevas.last else { return }
    ultimaN = ultima.n
    anotar("← \(nuevas.count) frase(s) nueva(s): \(nuevas.map { $0.wav }.joined(separator: " "))")
    colaFrases.append(contentsOf: nuevas.map { $0.wav })
    bajarSiguiente()
  }

  private func cortar() {
    corte += 1
    colaFrases = []
    bajada?.cancel()
    bajada = nil
    voz.stop()
    // Arrancar un reproductor con el motor parado (una llamada, unos cascos que se van) cierra la app: solo si corre.
    if motor.isRunning { voz.play() }
  }

  /// Baja las frases en orden, una tras otra, y las encola en el reproductor: suenan seguidas, sin huecos.
  private func bajarSiguiente() {
    guard enMarcha, bajada == nil, !colaFrases.isEmpty else { return }
    let nombre = colaFrases.removeFirst()
    guard let r = peticion("/wav/\(nombre)", [URLQueryItem(name: "g", value: String(format: "%.2f", ganancia))]) else { return }
    let deEsteCorte = corte
    let inicio = Date()
    let tarea = sesionRed.dataTask(with: r) { [weak self] datos, respuesta, error in
      guard let self = self else { return }
      self.cola.async {
        guard self.corte == deEsteCorte else { return } // cancelada o llegó tras un «calla»: no suena
        self.bajada = nil
        defer { self.bajarSiguiente() }
        let codigo = (respuesta as? HTTPURLResponse)?.statusCode ?? 0
        let ms = Int(Date().timeIntervalSince(inicio) * 1000)
        guard error == nil, codigo == 200, let datos = datos else {
          self.anotar("↓ no pude bajar \(nombre): \(codigo) en \(ms) ms \(error?.localizedDescription ?? "")")
          return
        }
        self.anotar("↓ \(nombre): \(datos.count) B en \(ms) ms")
        self.contacto()
        self.sonar(datos, nombre)
      }
    }
    bajada = tarea
    tarea.resume()
  }

  private func sonar(_ wav: Data, _ nombre: String) {
    let fichero = FileManager.default.temporaryDirectory.appendingPathComponent("voz-\(corte)-\(nombre)")
    do {
      try wav.write(to: fichero, options: [.atomic, .noFileProtection])
      defer { try? FileManager.default.removeItem(at: fichero) }
      let f = try AVAudioFile(forReading: fichero)
      guard let leido = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return }
      try f.read(into: leido)
      guard let buffer = aFormatoVoz(leido) else {
        anotar("♪ no pude convertir \(nombre) (\(describirFormato(f.processingFormat)))")
        return
      }
      guard motor.isRunning else {
        anotar("♪ \(nombre) no suena: el motor está parado")
        return
      }
      let segundos = Double(buffer.frameLength) / formatoVoz.sampleRate
      let deEsteCorte = corte
      voz.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
        guard let self = self else { return }
        self.cola.async {
          if self.corte == deEsteCorte { self.anotar("♪ sonó \(nombre)") }
        }
      }
      if !voz.isPlaying { voz.play() }
      anotar("♪ encolada \(nombre): \(String(format: "%.1f", segundos)) s, reproductor \(voz.isPlaying ? "sonando" : "parado")")
    } catch {
      anotar("♪ no pude leer \(nombre): \(error.localizedDescription)")
    }
  }

  /// Piper da 22.050 Hz mono: entonces pasa tal cual. Si un día cambia, se convierte aquí.
  private func aFormatoVoz(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    if b.format == formatoVoz { return b }
    guard let conv = AVAudioConverter(from: b.format, to: formatoVoz) else { return nil }
    let capacidad = AVAudioFrameCount(Double(b.frameLength) * formatoVoz.sampleRate / b.format.sampleRate) + 64
    guard let salida = AVAudioPCMBuffer(pcmFormat: formatoVoz, frameCapacity: capacidad) else { return nil }
    let entregado = Bandera()
    var error: NSError?
    let estado = conv.convert(to: salida, error: &error) { _, estadoEntrada in
      if entregado.hecha {
        estadoEntrada.pointee = .endOfStream
        return nil
      }
      entregado.hecha = true
      estadoEntrada.pointee = .haveData
      return b
    }
    return estado == .error || error != nil ? nil : salida
  }

  // MARK: - El contacto con el PC y los pitidos

  private func contacto() {
    ultimoContacto = Date()
    if sinPC {
      sinPC = false
      anotar("el PC vuelve")
      pitar([880, 1320], "el PC vuelve")
    }
    if ["conectando", "sin PC", "ficha mala"].contains(estadoActual) { fijarEstado("conectado", "el PC contesta") }
  }

  private func avisar403() {
    ultimoContacto = Date() // el PC contesta: no es «sin PC»
    sinPC = false
    if estadoActual != "ficha mala" { fijarEstado("ficha mala", "el PC contesta 403") }
    let ahora = Date()
    guard ahora.timeIntervalSince(ultimo403) > 30 else { return }
    ultimo403 = ahora
    anotar("el PC no acepta la ficha (403): revísala en los ajustes")
  }

  private func vigilarContacto() {
    let ahora = Date()
    if ahora.timeIntervalSince(ultimoTic) > 3 {
      anotar("vuelvo de estar suspendida \(Int(ahora.timeIntervalSince(ultimoTic))) s: no cuento ese rato como «sin PC»")
      ultimoContacto = ahora
    }
    ultimoTic = ahora
    guard enMarcha, !sinPC, ahora.timeIntervalSince(ultimoContacto) > plazoSinPC else { return }
    sinPC = true
    anotar("sin PC desde hace \(Int(plazoSinPC)) s")
    fijarEstado("sin PC", "más de \(Int(plazoSinPC)) s sin respuesta")
    pitar([660, 440], "sin PC")
  }

  /// Dos tonos cortos: subiendo, el PC vuelve; bajando, el PC no contesta.
  private func pitar(_ frecuencias: [Double], _ motivo: String) {
    guard motor.isRunning else {
      anotar("tono «\(motivo)» sin sonar: el motor está parado")
      return
    }
    let tasa = formatoVoz.sampleRate
    let tono = Int(tasa * 0.12)
    let hueco = Int(tasa * 0.06)
    let total = frecuencias.count * (tono + hueco)
    guard let b = AVAudioPCMBuffer(pcmFormat: formatoVoz, frameCapacity: AVAudioFrameCount(total)),
          let canal = b.floatChannelData else { return }
    b.frameLength = AVAudioFrameCount(total)
    var i = 0
    for f in frecuencias {
      for k in 0..<tono {
        let rampa = min(1.0, Double(min(k, tono - k)) / (tasa * 0.01))
        canal[0][i] = Float(0.3 * rampa * sin(2 * Double.pi * f * Double(k) / tasa))
        i += 1
      }
      for _ in 0..<hueco {
        canal[0][i] = 0
        i += 1
      }
    }
    pitidos.scheduleBuffer(b, completionHandler: nil)
    if !pitidos.isPlaying { pitidos.play() }
    anotar("tono: \(frecuencias.map { String(Int($0)) }.joined(separator: " → ")) Hz (\(motivo))")
  }

  // MARK: - Descripciones para el registro

  /// La frecuencia de la sesión, el micro de la ruta y su formato, y si el motor corre.
  private func estadoAudio() -> String {
    let s = AVAudioSession.sharedInstance()
    var micro = "-"
    if montado {
      micro = describirFormato(motor.inputNode.outputFormat(forBus: 0))
    }
    let entrada = s.currentRoute.inputs.first?.portType.rawValue ?? "?"
    return "sesión \(Int(s.sampleRate)) Hz, entrada \(entrada), micro \(micro), motor \(motor.isRunning ? "en marcha" : "parado")"
  }

  private func describirSesion() -> String {
    let s = AVAudioSession.sharedInstance()
    return "\(Int(s.sampleRate)) Hz, búfer \(Int(s.ioBufferDuration * 1000)) ms, latencia entrada \(Int(s.inputLatency * 1000)) ms y salida \(Int(s.outputLatency * 1000)) ms, categoría \(s.category.rawValue), modo \(s.mode.rawValue), opciones \(s.categoryOptions.rawValue), canales entrada \(s.inputNumberOfChannels), ruta \(describirRuta(s.currentRoute))"
  }

  private func describirRuta(_ r: AVAudioSessionRouteDescription) -> String {
    let ent = r.inputs.map { "\($0.portType.rawValue) «\($0.portName)»" }.joined(separator: " + ")
    let sal = r.outputs.map { "\($0.portType.rawValue) «\($0.portName)»" }.joined(separator: " + ")
    return "entrada \(ent.isEmpty ? "-" : ent), salida \(sal.isEmpty ? "-" : sal)"
  }

  private func describirFormato(_ f: AVAudioFormat) -> String {
    let muestra: String
    switch f.commonFormat {
    case .pcmFormatFloat32: muestra = "float32"
    case .pcmFormatFloat64: muestra = "float64"
    case .pcmFormatInt16: muestra = "int16"
    case .pcmFormatInt32: muestra = "int32"
    default: muestra = "otro"
    }
    return "\(Int(f.sampleRate)) Hz, \(f.channelCount) c, \(muestra), \(f.isInterleaved ? "entrelazado" : "planar")"
  }

  /// De la dirección del PC, solo la primera parte del nombre: el registro se copia y se pega.
  private func hostVisible(_ u: URL) -> String {
    guard let h = u.host, let primera = h.split(separator: ".").first else { return "?" }
    return "\(u.scheme ?? "?")://\(primera).…"
  }

  // MARK: - El estado y el registro

  private func fijarEstado(_ e: String, _ motivo: String = "") {
    if e != estadoActual { anotar("estado: \(estadoActual) → \(e)\(motivo.isEmpty ? "" : " (\(motivo))")") }
    estadoActual = e
    cerrojo.lock()
    estadoCopia = e
    cerrojo.unlock()
    alEstado?(e)
  }

  private func anotar(_ l: String) {
    let linea = "\(reloj.string(from: Date()))  \(l)"
    lineas.append(linea)
    if lineas.count > maxLineas { lineas.removeFirst(lineas.count - maxLineas) }
    cerrojo.lock()
    lineasCopia = lineas
    cerrojo.unlock()
    alRegistro?(linea)
  }
}
