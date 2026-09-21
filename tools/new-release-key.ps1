# Cria a chave que assina as versões do HollowDrivers (só precisa rodar UMA vez).
# A chave privada fica FORA do repositório. Guarde uma cópia num pendrive: sem ela não dá para publicar
# atualizações que os apps instalados aceitem.
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:USERPROFILE '.HollowDrivers'
$key = Join-Path $dir 'release-key.xml'
if (Test-Path $key) { throw "Já existe uma chave em $key. Não gere outra: os apps instalados só aceitam a atual." }
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(3072)
$rsa.PersistKeyInCsp = $false
[IO.File]::WriteAllText($key, $rsa.ToXmlString($true))
# só o próprio usuário pode ler
icacls $dir /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F" | Out-Null
"Chave privada: $key"
"Chave pública (vai dentro do HollowDrivers.ps1, em `$UpdatePubKey):"
$rsa.ToXmlString($false)
