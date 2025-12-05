# Wazuh Agent Deployment (Linux) – PineServer Home Lab

![Wazuh Agent](https://img.shields.io/badge/Wazuh-Agent%204.x-0078d7?logo=shield)
![OS](https://img.shields.io/badge/OS-Ubuntu%2022.04-orange?logo=ubuntu)
![Kubernetes](https://img.shields.io/badge/Kubernetes-K3s%20%2B%20Longhorn-blue?logo=kubernetes)
![GitOps](https://img.shields.io/badge/GitOps-ArgoCD-success?logo=argo)

This document is a **quick guide** to deploy a Wazuh agent on Linux in an environment like **pineserver**:

- Ubuntu 22.04 host
- k3s + Longhorn
- Wazuh Manager running in the `wazuh` namespace
- NodePort services for agent connectivity
- DNS name `wazuh.pineserver.local` pointing at the k3s node

It covers:

- Agent install on Linux  
- Connecting to Wazuh Manager (NodePort)  
- Enrollment **without password auth**  
- Enrollment **with password auth**  
- Two simple **automation scripts** using `agent-auth`

---

## Architecture Overview

```mermaid
flowchart LR
  subgraph HomeLAN
    Host1[Agent pineserver]
    Host2[Agent other host]
    Test[Agent test containers]
  end

  subgraph K3sCluster
    Master[Wazuh Manager master]
    Workers[Wazuh Manager workers]
    SvcEvents[Service wazuh-manager-worker NodePort 31924]
    SvcAuth[Service wazuh NodePort 31515]
  end

  Host1 -->|31924/tcp| SvcEvents
  Host2 -->|31924/tcp| SvcEvents
  Test -->|31924/tcp| SvcEvents

  Host1 -->|31515/tcp| SvcAuth
  Host2 -->|31515/tcp| SvcAuth
  Test -->|31515/tcp| SvcAuth
