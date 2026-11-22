# escape=`

ARG BASE_IMAGE=mcr.microsoft.com/dotnet/framework/runtime:4.8.1-windowsservercore-ltsc2025

FROM ${BASE_IMAGE}

SHELL ["powershell", "-NoProfile", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

COPY sqlserver c:/image

WORKDIR C:/src

CMD ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-NoProfile"]
