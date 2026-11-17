Pod::Spec.new do |s|
  s.name           = 'RakazoHealth'
  s.version        = '0.1.0'
  s.summary        = 'Pushes HealthKit samples to a self-hosted health service (homelab)'
  s.author         = ''
  s.homepage       = 'https://docs.expo.dev/modules/'
  s.platforms      = { :ios => '16.4' }
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'
  s.frameworks = 'HealthKit', 'BackgroundTasks'  # Compression 是 libcompression，import 时自动链接

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.source_files = '**/*.swift'
end
