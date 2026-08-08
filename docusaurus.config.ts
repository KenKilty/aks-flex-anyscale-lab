import type { Config } from "@docusaurus/types";
import type * as Preset from "@docusaurus/preset-classic";
import { themes as prismThemes } from "prism-react-renderer";

const config: Config = {
  title: "Run AI Where Your GPUs Are",
  tagline: "Use AKS Flex Node and Anyscale on Azure to bring Ray AI/ML workloads to reachable compute.",
  url: "https://example.invalid",
  baseUrl: "/",
  onBrokenLinks: "throw",
  organizationName: "Azure-Samples",
  projectName: "aks-flexnode-anyscale-sample",
  markdown: {
    mermaid: true,
    hooks: {
      onBrokenMarkdownLinks: "warn",
    },
  },
  themes: ["@docusaurus/theme-mermaid"],
  i18n: {
    defaultLocale: "en",
    locales: ["en"],
  },
  presets: [
    [
      "classic",
      {
        docs: {
          sidebarPath: "./sidebars.ts",
          editUrl: "https://github.com/Azure-Samples/aks-labs/tree/main/",
        },
        blog: false,
        theme: {
          customCss: "./src/css/custom.css",
        },
      } satisfies Preset.Options,
    ],
  ],
  themeConfig: {
    navbar: {
      title: "Run AI Where Your GPUs Are",
      items: [
        {
          type: "docSidebar",
          sidebarId: "tutorialSidebar",
          position: "left",
          label: "Workshops",
        },
      ],
    },
    docs: {
      sidebar: {
        hideable: true,
      },
    },
    footer: {
      style: "dark",
      copyright: `Copyright © ${new Date().getFullYear()} Microsoft. Built with Docusaurus.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
