# aios-voz-movil

Una app de iPhone que hace de micro y de altavoz de un asistente de voz que corre en un PC: dictas con el iPhone en el
bolsillo y la pantalla bloqueada, el PC transcribe y responde, y la respuesta suena por tus cascos. La puedes cortar
mientras habla.

Es un MVP personal, publicado para compilarlo en los runners de macOS de GitHub Actions. No lleva ninguna dirección,
ninguna credencial ni ningún dato de nadie: la dirección del PC y la ficha que le identifica se escriben en la propia
app y la ficha se guarda en el llavero del iPhone.

## Cómo funciona

- **Expo (SDK 58) y React Native** para la pantalla, que solo guarda los ajustes y enseña el estado y un registro.
- **Un módulo nativo en Swift** (`modules/aios-audio/ios/MotorVoz.swift`) que hace el trabajo de verdad: un
  `AVAudioEngine` con la unidad de voz de iOS (cancelación de eco, ruido y ganancia) que graba y reproduce a la vez, y
  que habla él mismo con el PC por HTTPS, sin pasar por el JavaScript, para seguir funcionando con la pantalla
  bloqueada (`UIBackgroundModes: audio`).
- **El protocolo** con el PC, con la ficha en la cabecera `X-Ficha`:
  - `POST /audio?rate=16000`: el micro en PCM int16 mono a 16 kHz, cada 250 ms;
  - `GET /salida`: lo que hay que decir, `{"gen", "ganancia", "frases": [{"n", "wav", "gen"}]}`, cada 400 ms;
  - `GET /wav/frase-N.wav`: cada frase en wav; si `gen` sube, se corta lo que suena y se tira la cola.
- **Dos rutas del micro**: el de los cascos (manos libres) o el del iPhone. Si el PC deja de contestar, dos tonos
  bajando; cuando vuelve, dos subiendo.

## Compilar

`.github/workflows/ios-sin-firma.yml` compila en cada cambio, **sin firmar**: hace el prebuild de Expo y el archivado de
Xcode con `CODE_SIGNING_ALLOWED=NO` y deja `AIOS-voz-sin-firmar.ipa` como artefacto. Comprueba que el módulo nativo va
dentro y que el `Info.plist` lleva el modo de fondo de audio, y deja en el resumen lo que tardó.

Para instalarlo hay que firmarlo, por ejemplo con AltStore y un Apple ID gratuito (la firma caduca a los 7 días), o con
una cuenta de desarrollador.

## Estado

MVP sin probar todavía en un iPhone. Este repositorio público es temporal: se retirará cuando la app se compile con una
cuenta de desarrollador de pago.

## Licencia

MIT, en `LICENSE`.
