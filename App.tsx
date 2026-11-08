// La app de la voz del AIOS (2026-11-08, plan brainstorms/2026-11-08-plan-app-iphone-brigada.md).
// El iPhone hace de micro y de altavoz del Mod aios-voz del PC, también con la pantalla bloqueada y fuera de casa (por
// la tailnet de Jonatan). El audio y la red los lleva el motor nativo (modules/aios-audio); esta pantalla solo guarda
// los ajustes, arranca y para, y enseña el estado y el registro. La dirección y la ficha no van en el código: se
// escriben aquí una vez y la ficha se guarda en el llavero del iPhone.
import { useEffect, useRef, useState } from 'react'
import { Pressable, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native'
import { StatusBar } from 'expo-status-bar'
import * as SecureStore from 'expo-secure-store'
import * as Clipboard from 'expo-clipboard'
import AiosAudio, { type Ruta } from './modules/aios-audio'

const CLAVE_BASE = 'aios-voz-base'
const CLAVE_FICHA = 'aios-voz-ficha'
const CLAVE_RUTA = 'aios-voz-ruta'
const CLAVE_ECO = 'aios-voz-eco'
const GANANCIA = 2.5 // hasta que el PC diga la suya

export default function App() {
  const [base, setBase] = useState('')
  const [ficha, setFicha] = useState('')
  const [ruta, setRuta] = useState<Ruta>('cascos')
  const [eco, setEco] = useState(true) // la cancelación de eco de iOS (la unidad de voz)
  const [estado, setEstado] = useState(AiosAudio.estado())
  const [nivel, setNivel] = useState<number | null>(null)
  const [lineas, setLineas] = useState<string[]>(() => AiosAudio.registro().slice(-150))
  const [aviso, setAviso] = useState('')
  const cargado = useRef(false)

  useEffect(() => {
    void (async () => {
      setBase((await SecureStore.getItemAsync(CLAVE_BASE)) ?? '')
      setFicha((await SecureStore.getItemAsync(CLAVE_FICHA)) ?? '')
      const r = await SecureStore.getItemAsync(CLAVE_RUTA)
      if (r === 'iphone' || r === 'cascos') setRuta(r)
      setEco((await SecureStore.getItemAsync(CLAVE_ECO)) !== 'no')
      cargado.current = true
    })()
    const subs = [
      AiosAudio.addListener('onEstado', e => setEstado(e.estado)),
      AiosAudio.addListener('onRegistro', e => setLineas(prev => [...prev.slice(-149), e.linea])),
      AiosAudio.addListener('onNivel', e => setNivel(e.db)),
    ]
    return () => subs.forEach(s => s.remove())
  }, [])

  const guardar = async () => {
    await SecureStore.setItemAsync(CLAVE_BASE, base.trim())
    await SecureStore.setItemAsync(CLAVE_FICHA, ficha.trim())
    await SecureStore.setItemAsync(CLAVE_RUTA, ruta)
    await SecureStore.setItemAsync(CLAVE_ECO, eco ? 'si' : 'no')
  }

  const empezar = async () => {
    setAviso('')
    try {
      await guardar()
      await AiosAudio.empezar({ base: base.trim(), ficha: ficha.trim(), ruta, ganancia: GANANCIA, unidadDeVoz: eco })
    } catch (e) {
      setAviso(e instanceof Error ? e.message : String(e))
    }
  }

  const parar = async () => {
    await AiosAudio.parar()
    setNivel(null)
  }

  const enMarcha = !['parado', 'sin permiso de micro'].includes(estado)

  return (
    <View style={estilos.pantalla}>
      <StatusBar style="auto" />
      <Text style={estilos.titulo}>AIOS por voz</Text>
      <Text style={[estilos.estado, estado === 'conectado' ? estilos.bien : null]}>
        {estado}
        {nivel !== null && enMarcha ? `  ·  micro ${Math.round(nivel)} dB` : ''}
      </Text>
      {aviso !== '' && <Text style={estilos.aviso}>{aviso}</Text>}

      <Text style={estilos.etiqueta}>Dirección del PC (la de tailscale serve)</Text>
      <TextInput
        style={estilos.campo}
        value={base}
        onChangeText={setBase}
        placeholder="https://<pc>.<tailnet>.ts.net"
        autoCapitalize="none"
        autoCorrect={false}
        keyboardType="url"
        editable={!enMarcha}
      />
      <Text style={estilos.etiqueta}>Ficha (pégala desde tu gestor de contraseñas)</Text>
      <TextInput
        style={estilos.campo}
        value={ficha}
        onChangeText={setFicha}
        placeholder="la ficha de la escucha del PC"
        autoCapitalize="none"
        autoCorrect={false}
        secureTextEntry
        editable={!enMarcha}
      />
      <View style={estilos.fila}>
        {(['cascos', 'iphone'] as const).map(r => (
          <Pressable
            key={r}
            style={[estilos.opcion, ruta === r ? estilos.opcionElegida : null]}
            onPress={() => !enMarcha && setRuta(r)}
          >
            <Text style={ruta === r ? estilos.textoBoton : estilos.textoOpcion}>
              {r === 'cascos' ? 'Micro de los cascos' : 'Micro del iPhone'}
            </Text>
          </Pressable>
        ))}
      </View>
      <View style={estilos.fila}>
        <Pressable
          style={[estilos.opcion, eco ? estilos.opcionElegida : null]}
          onPress={() => !enMarcha && setEco(!eco)}
        >
          <Text style={eco ? estilos.textoBoton : estilos.textoOpcion}>
            {eco ? 'Cancelación de eco: SÍ' : 'Cancelación de eco: NO'}
          </Text>
        </Pressable>
      </View>

      <View style={estilos.fila}>
        <Pressable style={[estilos.boton, estilos.empezar]} onPress={() => void empezar()} disabled={enMarcha}>
          <Text style={estilos.textoBoton}>Empezar</Text>
        </Pressable>
        <Pressable style={[estilos.boton, estilos.parar]} onPress={() => void parar()}>
          <Text style={estilos.textoBoton}>Parar</Text>
        </Pressable>
        <Pressable
          style={[estilos.boton, estilos.copiar]}
          onPress={() => {
            // El registro entero del motor (hasta 6.000 líneas), no solo lo que cabe en la pantalla.
            const todo = AiosAudio.registro()
            void Clipboard.setStringAsync(todo.join('\n')).then(() => setAviso(`Registro copiado: ${todo.length} líneas`))
          }}
        >
          <Text style={estilos.textoBoton}>Copiar registro</Text>
        </Pressable>
      </View>

      <ScrollView style={estilos.lista}>
        <Text style={estilos.mono}>{lineas.join('\n')}</Text>
      </ScrollView>
    </View>
  )
}

const estilos = StyleSheet.create({
  pantalla: { flex: 1, backgroundColor: '#fff', paddingTop: 64, paddingHorizontal: 16 },
  titulo: { fontSize: 22, fontWeight: '600', marginBottom: 6 },
  estado: { fontSize: 17, marginBottom: 8, color: '#7f8c8d' },
  bien: { color: '#1e8449' },
  aviso: { fontSize: 14, color: '#c0392b', marginBottom: 8 },
  etiqueta: { fontSize: 13, color: '#555', marginTop: 6 },
  campo: { borderWidth: 1, borderColor: '#ccc', borderRadius: 8, padding: 10, fontSize: 15, marginTop: 4 },
  fila: { flexDirection: 'row', gap: 8, marginTop: 12 },
  opcion: { flex: 1, padding: 10, borderRadius: 8, borderWidth: 1, borderColor: '#2c3e50', alignItems: 'center' },
  opcionElegida: { backgroundColor: '#2c3e50' },
  textoOpcion: { color: '#2c3e50', fontSize: 14, fontWeight: '600' },
  boton: { paddingVertical: 14, paddingHorizontal: 14, borderRadius: 10 },
  empezar: { backgroundColor: '#c0392b' },
  parar: { backgroundColor: '#2c3e50' },
  copiar: { backgroundColor: '#7f8c8d' },
  textoBoton: { color: '#fff', fontSize: 15, fontWeight: '600' },
  lista: { flex: 1, marginTop: 12 },
  mono: { fontFamily: 'Menlo', fontSize: 11 },
})
