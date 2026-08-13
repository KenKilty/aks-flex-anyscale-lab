import type { SidebarsConfig } from "@docusaurus/plugin-content-docs";

const sidebars: SidebarsConfig = {
  tutorialSidebar: [
    {
      type: "category",
      label: "Run AI Where Your GPUs Are",
      link: {
        type: "doc",
        id: "ai-workloads-on-aks/aks-flex-anyscale-multi-region",
      },
      items: [
        "ai-workloads-on-aks/key-concepts",
        "ai-workloads-on-aks/module-01-environment-setup",
        "ai-workloads-on-aks/module-02-aks-foundation",
        "ai-workloads-on-aks/module-03-flex-node",
        "ai-workloads-on-aks/module-04-anyscale-binding",
        "ai-workloads-on-aks/module-05-autoscaling",
        "ai-workloads-on-aks/module-06-workload-results",
        "ai-workloads-on-aks/module-07-teardown",
      ],
    },
    "DEVELOPER",
  ],
};

export default sidebars;
