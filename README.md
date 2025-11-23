# Patroni High-Availability Cluster with Ansible (Proof-of-Concept)

## Objective
This repository contains an Ansible project for deploying a distributed, high-availability PostgreSQL cluster using Patroni. This project was developed as a Proof-of-Concept (PoC) to evaluate a modern, open-source HA solution for enterprise use within the Udviklings- og Forenklingsstyrelsen (UFST) infrastructure.

## Architecture
This project simulates a multi-host deployment:
*   **3 Virtual Hosts:** The deployment targets three separate nodes (`node1`, `node2`, `node3`).
*   **Distributed Services:** Each node runs its own Patroni and Etcd container.
*   **HAProxy:** A single HAProxy instance is deployed on `node1` to act as the single entry point for the database cluster.
*   **Automation:** The entire process, from installing Docker to running containers, is fully automated with a single Ansible playbook.

## How to Run
1.  Ensure you have `ansible` installed.
2.  Clone this repository.
3.  Update the `inventory.ini` file with the actual IP addresses of your target servers.
4.  Run the deployment: `ansible-playbook -i inventory.ini deploy_cluster.yml`

## Status
**Proof-of-Concept.** This implementation successfully demonstrates a realistic multi-host deployment of a Patroni cluster. The findings and performance benchmarks were presented in a technical report for the architectural committee.