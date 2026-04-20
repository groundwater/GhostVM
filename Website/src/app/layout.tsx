import type { Metadata } from "next"
import { ThemeProvider } from "next-themes"
import Navbar from "@/components/layout/Navbar"
import Footer from "@/components/layout/Footer"
import "./globals.css"

export const metadata: Metadata = {
  metadataBase: new URL("https://ghostvm.org"),
  title: "GhostVM - Mac Virtual Machine for Secure Development",
  description:
    "Mac virtual machine for secure development. Run isolated macOS workspaces for AI agents, sandboxed code, and untrusted projects. Apple Silicon native with instant clones.",
  openGraph: {
    title: "GhostVM - Mac Virtual Machine for Secure Development",
    description:
      "Mac virtual machine for secure development. Run isolated macOS workspaces for AI agents, sandboxed code, and untrusted projects. Apple Silicon native.",
    url: "https://ghostvm.org",
    siteName: "GhostVM",
    images: [
      {
        url: "https://ghostvm.org/images/screenshots/hero-screenshot.jpg",
        width: 1200,
        height: 630,
        alt: "GhostVM - Agent Workspaces on macOS",
      },
    ],
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "GhostVM - Mac Virtual Machine for Secure Development",
    description:
      "Mac virtual machine for secure development. Run isolated macOS workspaces for AI agents, sandboxed code, and untrusted projects. Apple Silicon native.",
    images: ["https://ghostvm.org/images/screenshots/hero-screenshot.jpg"],
  },
}

const jsonLd = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: "GhostVM",
  applicationCategory: "DeveloperApplication",
  operatingSystem: "macOS",
  offers: {
    "@type": "Offer",
    price: "0",
    priceCurrency: "USD",
  },
  description:
    "Mac virtual machine for secure development. Run isolated macOS workspaces for AI agents, sandboxed code, and untrusted projects.",
  url: "https://ghostvm.org",
  downloadUrl: "https://github.com/groundwater/GhostVM/releases/latest",
  softwareVersion: "2.11.0",
  author: {
    "@type": "Organization",
    name: "GhostVM",
    url: "https://ghostvm.org",
  },
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
        />
      </head>
      <body className="min-h-screen bg-white dark:bg-gray-950 text-gray-900 dark:text-gray-100 antialiased">
        <ThemeProvider attribute="class" defaultTheme="system" enableSystem>
          <Navbar />
          <main>{children}</main>
          <Footer />
        </ThemeProvider>
      </body>
    </html>
  )
}
