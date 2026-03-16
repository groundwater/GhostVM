import type { Metadata } from "next"
import { ThemeProvider } from "next-themes"
import Navbar from "@/components/layout/Navbar"
import Footer from "@/components/layout/Footer"
import "./globals.css"

export const metadata: Metadata = {
  metadataBase: new URL("https://ghostvm.org"),
  title: "GhostVM - Agent Workspaces on macOS",
  description:
    "GhostVM is a native macOS app for running isolated agent workspaces on macOS. Deep host integration, scriptable CLI, instant clones, and self-contained bundles.",
  openGraph: {
    title: "GhostVM - Agent Workspaces on macOS",
    description:
      "GhostVM is a native macOS app for running isolated agent workspaces on macOS. Deep host integration, scriptable CLI, instant clones, and self-contained bundles.",
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
    title: "GhostVM - Agent Workspaces on macOS",
    description:
      "GhostVM is a native macOS app for running isolated agent workspaces on macOS. Deep host integration, scriptable CLI, instant clones, and self-contained bundles.",
    images: ["https://ghostvm.org/images/screenshots/hero-screenshot.jpg"],
  },
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="en" suppressHydrationWarning>
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
