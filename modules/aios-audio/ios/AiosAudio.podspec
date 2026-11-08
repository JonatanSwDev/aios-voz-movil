Pod::Spec.new do |s|
  s.name           = 'AiosAudio'
  s.version        = '1.0.0'
  s.summary        = 'Motor de audio nativo de la app de la voz del AIOS'
  s.description    = 'Graba y reproduce a la vez con la unidad de voz de iOS y habla con la escucha del PC'
  s.author         = ''
  s.homepage       = 'https://docs.expo.dev/modules/'
  s.platforms      = {
    :ios => '16.4'
  }
  # Modo de lenguaje 5: el motor usa colas de GCD, no la concurrencia estricta de Swift 6.
  s.swift_version  = '5.9'
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  # Swift/Objective-C compatibility
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }

  s.source_files = "**/*.{h,m,mm,swift,hpp,cpp}"
end
