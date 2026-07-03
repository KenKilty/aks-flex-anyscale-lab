import React from "react";
import Link from "@docusaurus/Link";
import Layout from "@theme/Layout";

export default function Home(): React.JSX.Element {
  return (
    <Layout
      title="AKS Flex Node + Anyscale on Azure"
      description="Use AKS Flex Node to extend a single AKS cluster to GPUs in other Azure regions, on-premises bare metal, or other clouds — then run distributed AI workloads through Anyscale without changing your code."
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
          AKS Flex Node + Anyscale on Azure
        </h1>
        <p
          style={{
            fontSize: "1.25rem",
            maxWidth: 780,
            margin: "0 auto 2rem",
            opacity: 0.9,
          }}
        >
          Learn how to extend a single AKS cluster across Azure regions, on-premises
          machines, or other clouds using{" "}
          <strong>AKS Flex Node</strong>, then run distributed GPU workloads through{" "}
          <strong>Anyscale</strong> — without changing your workload code.
        </p>
        <Link
          className="button button--secondary button--lg"
          to="/docs/ai-workloads-on-aks/aks-flex-anyscale-multi-region"
        >
          Start the lab ⏱ ~75 min
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
              title: "Multi-region capacity",
              body:
                "Attach worker nodes from any Azure region, on-premises server, or external cloud to one AKS control plane with AKS Flex Node.",
            },
            {
              title: "Distributed AI workloads",
              body:
                "Use Ray Train and DeepSpeed through Anyscale to saturate GPU capacity that spans geographic and infrastructure boundaries.",
            },
            {
              title: "Repeatable proof artifacts",
              body:
                "Every lab run produces machine-readable placement and saturation evidence so you can verify the topology is actually working.",
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
