# Go
export GOPATH="$HOME/go"
export GOTOOLCHAIN=local
case ":$PATH:" in *":$GOPATH/bin:"*) ;; *) PATH="$PATH:$GOPATH/bin" ;; esac
# .NET
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_ROOT=/usr/lib/dotnet
export DOTNET_NOLOGO=1
case ":$PATH:" in *":$HOME/.dotnet/tools:"*) ;; *) PATH="$PATH:$HOME/.dotnet/tools" ;; esac
export PATH
