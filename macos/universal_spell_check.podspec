Pod::Spec.new do |s|
  s.name             = 'universal_spell_check'
  s.version          = '0.1.0'
  s.summary          = 'Spell checking for Flutter text fields on macOS via NSSpellChecker.'
  s.description      = <<-DESC
macOS implementation of universal_spell_check: exposes NSSpellChecker
(misspelled ranges and guesses) to Flutter's SpellCheckService.
                       DESC
  s.homepage         = 'https://github.com/Manish1Pandey/universal_spell_check'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Manish Kumar Panday' => 'https://github.com/Manish1Pandey' }

  s.source           = { :path => '.' }
  s.source_files     = 'universal_spell_check/Sources/universal_spell_check/**/*.swift'
  s.resource_bundles = {'universal_spell_check_privacy' => ['universal_spell_check/Sources/universal_spell_check/Resources/PrivacyInfo.xcprivacy']}

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
