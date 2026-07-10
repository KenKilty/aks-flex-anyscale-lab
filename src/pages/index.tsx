import React from "react";
import Link from "@docusaurus/Link";
import Layout from "@theme/Layout";

export default function Home(): React.JSX.Element {
  return (
    <Layout
      title="Run AI Where Your GPUs Are"
      description="Use AKS Flex Node and Anyscale on Azure to run Ray AI/ML workloads where your compute and GPUs already are."
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
          Learn how <strong>AKS Flex Node</strong> lets AKS use reachable Linux
          compute in another region, datacenter, or cloud environment, then use{" "}
          <strong>Anyscale on Azure</strong> to run Ray AI/ML workloads on that
          capacity without changing your workload code.
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
              title: "Multi-region capacity",
              body:
                "Attach reachable Linux compute from another Azure region, an on-premises server, or another cloud environment to one AKS control plane.",
            },
            {
              title: "Ray AI/ML workloads",
              body:
                "Use Anyscale on Azure to submit Ray Jobs onto the AKS and Flex capacity profile you define.",
            },
            {
              title: "Placement proof",
              body:
                "Validate proof summaries and Kubernetes placement data so job success is tied to the node where the worker actually ran.",
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
