// El módulo de Expo de la app de la voz: le da al JavaScript empezar, parar, el estado y el registro del motor
// (MotorVoz.swift), y le manda tres eventos. El JavaScript no toca el audio ni la red.

import ExpoModulesCore

struct AjustesVoz: Record {
  @Field var base: String = ""
  @Field var ficha: String = ""
  @Field var ruta: String = "cascos" // «cascos» (manos libres) o «iphone» (el micro del aparato)
  @Field var ganancia: Double = 2.5
  @Field var unidadDeVoz: Bool = true // la cancelación de eco de iOS; se puede apagar con los cascos (8-nov)
}

public class AiosAudioModule: Module {
  private let motor = MotorVoz()

  public func definition() -> ModuleDefinition {
    Name("AiosAudio")

    Events("onEstado", "onRegistro", "onNivel")

    OnCreate {
      self.motor.alEstado = { [weak self] e in self?.sendEvent("onEstado", ["estado": e]) }
      self.motor.alRegistro = { [weak self] l in self?.sendEvent("onRegistro", ["linea": l]) }
      self.motor.alNivel = { [weak self] db in self?.sendEvent("onNivel", ["db": db]) }
    }

    AsyncFunction("empezar") { (ajustes: AjustesVoz, promise: Promise) in
      let texto = ajustes.base.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let base = URL(string: texto), base.scheme == "https" || base.scheme == "http", base.host != nil else {
        promise.reject("ERR_DIRECCION", "La dirección del PC no es una URL: escribe https://<pc>.<tailnet>.ts.net")
        return
      }
      guard ajustes.ficha.count >= 16 else {
        promise.reject("ERR_FICHA", "Falta la ficha, o es demasiado corta")
        return
      }
      let a = MotorVoz.Ajustes(
        base: base,
        ficha: ajustes.ficha,
        microDeLosCascos: ajustes.ruta != "iphone",
        ganancia: ajustes.ganancia,
        unidadDeVoz: ajustes.unidadDeVoz
      )
      self.motor.empezar(a) { error in
        if let error = error {
          promise.reject("ERR_AUDIO", error)
        } else {
          promise.resolve()
        }
      }
    }

    AsyncFunction("parar") {
      self.motor.parar()
    }

    Function("estado") {
      return self.motor.estado()
    }

    Function("registro") {
      return self.motor.registro()
    }

    OnDestroy {
      self.motor.parar()
    }
  }
}
