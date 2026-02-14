import Hero from "@/components/landing/Hero";

import ScreenshotShowcase from "@/components/landing/ScreenshotShowcase";
import AutomationSection from "@/components/landing/AutomationSection";
import IntegrationSection from "@/components/landing/IntegrationSection";
import FeatureGrid from "@/components/landing/FeatureGrid";
import SecuritySection from "@/components/landing/SecuritySection";
import VMIconShowcase from "@/components/landing/VMIconShowcase";
import DownloadCTA from "@/components/landing/DownloadCTA";

export default function Home() {
  return (
    <>
      <Hero />
      <IntegrationSection />
      <ScreenshotShowcase />
      <FeatureGrid />
      <SecuritySection />
      <VMIconShowcase />
      <AutomationSection />
      <DownloadCTA />
    </>
  );
}
