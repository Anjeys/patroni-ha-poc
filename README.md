# Patroni High-Availability PostgreSQL Cluster (PoC)

## 📌 Overview
This repository contains an Infrastructure-as-Code (IaC) solution for deploying a fault-tolerant, high-availability **PostgreSQL** cluster using **Patroni**, **Etcd**, and **HAProxy**.

This project was developed as a strategic **Proof-of-Concept (PoC)** to evaluate modern open-source HA solutions for enterprise-grade infrastructure within the **Udviklings- og Forenklingsstyrelsen (UFST)** context. It demonstrates a fully automated deployment pipeline capable of surviving node failures with zero manual intervention.

---

## 🏗️ Architecture

The solution simulates a distributed multi-host environment orchestrated via Ansible:

*   **Cluster Nodes:** 3 Virtual Hosts (`node1`, `node2`, `node3`).
*   **Consensus Store:** A distributed **Etcd 3.5** cluster ensures quorum and stores cluster state.
*   **Database Management:** **Patroni** manages PostgreSQL instances, handling leader elections and automatic failover.
*   **Load Balancing:** **HAProxy** acts as the single entry point, automatically routing read/write traffic to the Master and read-only traffic to Replicas.
*   **Containerization:** All components run as isolated Docker containers using `network_mode: host` for maximum performance.

---

## 🛠️ Technical Stack

| Component | Technology | Version | Purpose |
|---|---|---|---|
| **Automation** | Ansible | 2.10+ | Configuration Management & Deployment |
| **Database** | PostgreSQL | 14 (via Patroni) | Relational Database Engine |
| **Orchestration** | Patroni | 2.1.4 | HA Template & Failover Manager |
| **Consensus** | Etcd | 3.5 | Distributed Key-Value Store |
| **Routing** | HAProxy | 2.5 | TCP Load Balancer |
| **Runtime** | Docker | 20.10+ | Container Engine |

---

## 🚀 Features Implemented

*   ✅ **Zero Data Loss:** Synchronous replication configuration capabilities.
*   ✅ **Self-Healing:** Automatic promotion of a replica if the Master node fails (<10s downtime).
*   ✅ **Split-Brain Protection:** Uses Etcd quorum to prevent multiple masters.
*   ✅ **Traffic Separation:**
    *   **Port 5000:** Master (Read/Write)
    *   **Port 5001:** Replicas (Read Only / Reporting)
*   ✅ **Persistence:** Data volumes mapped to host filesystem to ensure data survival across container restarts.

---

## 📋 Prerequisites

*   **Control Node:** Linux/WSL with Ansible installed.
*   **Target Nodes:** 3 Ubuntu Servers with SSH access.
*   **Networking:** All nodes must communicate on ports `2379`, `2380` (Etcd), `5432` (Postgres), `8008` (Patroni API).

---

## ⚙️ How to Run

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/your-username/patroni-ha-ansible-poc.git
    cd patroni-ha-ansible-poc
    ```

2.  **Configure Inventory:**
    Update `inventory.ini` with your actual server IP addresses:
    ```ini
    [cluster_nodes]
    node1 ansible_host=192.168.1.101
    node2 ansible_host=192.168.1.102
    node3 ansible_host=192.168.1.103
    ```

3.  **Deploy Cluster:**
    Run the main playbook:
    ```bash
    ansible-playbook -i inventory.ini deploy_cluster.yml
    ```

4.  **Verify Status:**
    Check HAProxy stats at `http://<node1-ip>:7000` or query the cluster via Patroni API:
    ```bash
    curl http://<node1-ip>:8008/cluster
    ```

---

## 📈 Outcome

This PoC successfully demonstrated a realistic, automated deployment of a Patroni cluster.
**Key Results:**
*   Achieved automated failover time of **<10 seconds**.
*   Verified zero-downtime maintenance capabilities (rolling restarts).
*   The findings and performance benchmarks were documented and presented in a technical report for the architectural committee, serving as the basis for the production implementation roadmap.