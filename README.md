# Enterprise PostgreSQL High-Availability Cluster (PoC)

## 📌 Overview
This repository contains an advanced Infrastructure-as-Code (IaC) solution for deploying a fault-tolerant, high-availability **PostgreSQL** cluster. It integrates **Patroni**, **Etcd**, **HAProxy**, **PgBouncer**, and **pgBackRest**.

This project was developed as a strategic **Proof-of-Concept (PoC)** to evaluate modern open-source HA and Disaster Recovery solutions for enterprise-grade infrastructure within the **Udviklings- og Forenklingsstyrelsen (UFST)** context. It demonstrates a fully automated deployment pipeline capable of surviving node failures and preventing connection storms with zero manual intervention.

---

## 🏗️ Architecture

The solution simulates a bare-metal distributed environment locally using Docker Compose (with `systemd` and `cgroup v2` integrations) and configures the stack entirely via Ansible:

*   **Cluster Nodes (Databases):** 3 Nodes (`node1`, `node2`, `node3`).
*   **Access/Backup Node:** 1 Node (`balancer`).
*   **Consensus Store:** A distributed **Etcd** cluster ensures quorum and stores cluster state.
*   **Database Management:** **Patroni** manages PostgreSQL instances, handling leader elections and automatic failover.
*   **L4 Routing:** **HAProxy** dynamically routes read/write traffic to the Master by querying the Patroni REST API (`GET /master`).
*   **Connection Pooling:** **PgBouncer** is configured in `transaction` pool mode to protect the database from connection storms.
*   **Disaster Recovery:** **pgBackRest** acts as a centralized backup repository, utilizing a fully automated SSH Full Mesh network to securely pull/push WAL archives for Point-in-Time Recovery (PITR).

---

## 🛠️ Technical Stack

| Component | Technology | Purpose |
|---|---|---|
| **Automation** | Ansible 2.10+ | Modular Configuration Management (Roles) |
| **Database** | PostgreSQL 14 | Relational Database Engine |
| **Orchestration** | Patroni | HA Template & Failover Manager |
| **Consensus** | Etcd | Distributed Key-Value Store |
| **Routing** | HAProxy | TCP Load Balancer (L4) |
| **Pooling** | PgBouncer | Transaction-level Connection Pooler |
| **Backups/PITR** | pgBackRest | Disaster Recovery & WAL Archiving |
| **Infrastructure** | Docker / Compose | Bare-metal Emulation (Systemd, Static IPAM) |

---

## 🚀 Features Implemented

*   ✅ **Zero Data Loss:** Synchronous replication configuration capabilities and continuous WAL archiving.
*   ✅ **Self-Healing:** Automatic promotion of a replica if the Master node fails (<10s downtime).
*   ✅ **Split-Brain Protection:** Uses Etcd quorum to prevent multiple masters.
*   ✅ **Connection Storm Protection:** PgBouncer wraps physical connections, exposing port `6432` to the application.
*   ✅ **Automated Trust Network:** Ansible dynamically generates and distributes RSA keys across all nodes for passwordless SSH (Full Mesh).
*   ✅ **Cgroups v2 Compatibility:** Infrastructure resolves modern Linux kernel isolation issues, running `systemd` natively inside Docker containers.

---

## ⚙️ How to Run

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/Anjeys/patroni-ha-poc.git
    cd patroni-ha-poc
    ```

2.  **Spin up the Infrastructure:**
    This builds the underlying OS containers with systemd and static IP networks.
    ```bash
    docker compose up -d --build
    ```

3.  **Deploy the Cluster via Ansible:**
    Run the main playbook to configure Etcd, Patroni, HAProxy, PgBouncer, and pgBackRest.
    ```bash
    ansible-playbook -i inventory.ini playbook.yml
    ```

4.  **Verify Status:**
    Check the cluster topology via Patroni:
    ```bash
    docker exec -it node1 patronictl -c /etc/patroni/config.yml list
    ```
    Verify the application access layer via PgBouncer:
    ```bash
    psql -h 172.18.0.5 -p 6432 -U postgres -d postgres
    ```

---

## 📈 Outcome

This PoC successfully demonstrated a realistic, automated deployment of an Enterprise PostgreSQL architecture.
**Key Results:**
*   Achieved automated failover time of **<10 seconds**.
*   Secured the database against high-concurrency memory exhaustion via PgBouncer.
*   Implemented a robust Disaster Recovery pipeline via pgBackRest.
*   The findings and performance benchmarks were documented and presented in a technical report for the architectural committee, serving as the basis for the production implementation roadmap.
