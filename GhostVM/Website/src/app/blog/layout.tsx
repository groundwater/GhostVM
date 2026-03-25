export default function BlogLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <div className="max-w-3xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
      <article className="prose prose-gray dark:prose-invert max-w-none">
        {children}
      </article>
    </div>
  );
}
