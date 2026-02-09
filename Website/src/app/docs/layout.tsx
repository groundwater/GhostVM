import DocsSidebar from "@/components/layout/DocsSidebar";

export default function DocsLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
      <div className="flex gap-12">
        <DocsSidebar />
        <div className="flex-1 min-w-0">
          <article className="prose prose-gray dark:prose-invert max-w-none">
            {children}
          </article>
        </div>
      </div>
    </div>
  );
}
