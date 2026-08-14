import React from "react";
import Link from "@docusaurus/Link";
import Layout from "@theme/Layout";

export default function Home(): React.JSX.Element {
  return (
    <Layout
      title="Run AI Where Your GPUs Are"
      description="Connect computing power in two Azure regions, run a small distributed AI training job, and prove where the work ran."
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
          Learn how one AI training job can share work between machines in two
          Azure regions. You will connect an extra Linux machine to Azure
          Kubernetes Service (AKS), run a small model-training exercise across
          both locations, and prove which machines did the work. No prior
          experience with Ray, Kubernetes, or Anyscale is required.
        </p>
        <div
          style={{
            display: "flex",
            flexWrap: "wrap",
            gap: "0.75rem",
            justifyContent: "center",
          }}
        >
          <Link
            className="button button--secondary button--lg"
            to="/docs/ai-workloads-on-aks/aks-flex-anyscale-multi-region"
          >
            Start the lab, about 75 min
          </Link>
          <Link
            className="button button--outline button--secondary button--lg"
            to="/docs/ai-workloads-on-aks/key-concepts"
          >
            Read the key concepts
          </Link>
        </div>
      </header>

      <main style={{ margin: "0 auto", maxWidth: 960, padding: "3rem 1.5rem" }}>
        <h2 style={{ marginTop: 0, textAlign: "center" }}>What you will do</h2>
        <p
          style={{
            margin: "0 auto 2rem",
            maxWidth: 680,
            textAlign: "center",
          }}
        >
          Build the two-location environment, run a real but intentionally small
          training exercise, and collect evidence that shows where the work ran.
        </p>
        <section
          aria-label="Lab activities"
          style={{
            display: "grid",
            gridTemplateColumns: "repeat(auto-fit, minmax(260px, 1fr))",
            gap: "1.5rem",
          }}
        >
          {[
            {
              title: "Create the home base",
              body:
                "Create Azure Kubernetes Service (AKS) in one region. It acts as the home base that coordinates the training job.",
            },
            {
              title: "Add a machine in another region",
              body:
                "Connect a Linux virtual machine in a second region with AKS Flex Node, then check that it can communicate with the home cluster.",
            },
            {
              title: "Train across both locations",
              body:
                "Use Anyscale to submit the training exercise, then compare its results with records showing which machine ran each part.",
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
