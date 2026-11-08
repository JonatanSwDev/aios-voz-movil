// La cara en TypeScript del módulo nativo AiosAudio (ios/AiosAudioModule.swift). Solo iOS.
import { NativeModule, requireNativeModule } from 'expo'

export type Ruta = 'cascos' | 'iphone'

export type AjustesVoz = {
  base: string // https://<pc>.<tailnet>.ts.net, la de tailscale serve
  ficha: string
  ruta: Ruta
  ganancia: number
  unidadDeVoz: boolean // la cancelación de eco de iOS
}

export type AiosAudioEvents = {
  onEstado: (e: { estado: string }) => void
  onRegistro: (e: { linea: string }) => void
  onNivel: (e: { db: number }) => void
}

declare class AiosAudioModule extends NativeModule<AiosAudioEvents> {
  empezar(ajustes: AjustesVoz): Promise<void>
  parar(): Promise<void>
  estado(): string
  registro(): string[]
}

export default requireNativeModule<AiosAudioModule>('AiosAudio')
