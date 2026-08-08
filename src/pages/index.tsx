import React from "react";
import Link from "@docusaurus/Link";
import Layout from "@theme/Layout";

export default function Home(): React.JSX.Element {
  return (
    <Layout
      title="Run AI Where Your GPUs Are"
      description="Build a multi-region AKS environment, connect a Flex node, and run a Ray workload through Anyscale on Azure."
    >
      <header
        style={{
          background: "var(--ifm-color-primary)",
          color: "#fff",
          padding: "4rem 2rem",
          textAlign: "center",
        }}
      >
        <h1 style={{ fontSize: "2.5rem", marginBottom: "1rem" }}>
          Run AI Where Your GPUs Are
        </h1>
        <p
          style={{
            fontSize: "1.25rem",
            maxWidth: 780,
            margin: "0 auto 2rem",
            opacity: 0.9,
          }}
        >
          In this hands-on lab, you connect Linux compute in another Azure
          region to an AKS cluster with <strong>AKS Flex Node</strong>. You then
          use <strong>Anyscale on Azure</strong> to run a Ray workload across
          the AKS and Flex nodes and confirm where each part of the job ran.
        </p>
        <Link
          className="button button--secondary button--lg"
          to="/docs/ai-workloads-on-aks/aks-flex-anyscale-multi-region"
        >
          Start the lab, about 75 min
        </Link>
      </header>

      <main style={{ margin: "0 auto", maxWidth: 960, padding: "3rem 1.5rem" }}>
        <section
          style={{
            display: "grid",
            gridTemplateColumns: "repeat(auto-fit, minmax(260px, 1fr))",
            gap: "1.5rem",
          }}
        >
          {[
            {
              title: "Build the foundation",
              body:
                "Create an AKS cluster in one Azure region and prepare secure network connectivity to a second region.",
            },
            {
              title: "Connect a Flex node",
              body:
                "Join a Linux VM to the cluster, verify pod networking and DNS, and make the node available for workloads.",
            },
            {
              title: "Run and verify a Ray job",
              body:
                "Submit a job through Anyscale, confirm the worker ran on the Flex node, and save the workload and storage results.",
            },
          ].map(({ title, body }) => (
            <div
              key={title}
              style={{
                border: "1px solid var(--ifm-color-emphasis-300)",
                borderRadius: 8,
                padding: "1.5rem",
              }}
            >
              <h3 style={{ marginTop: 0 }}>{title}</h3>
              <p style={{ marginBottom: 0 }}>{body}</p>
            </div>
          ))}
        </section>
      </main>
    </Layout>
  );
}
