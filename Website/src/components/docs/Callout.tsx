import { Info, AlertTriangle, CheckCircle } from "lucide-react";
import { type ReactNode } from "react";

const variants = {
  info: {
    icon: Info,
    bg: "bg-blue-50 dark:bg-blue-950/30",
    border: "border-blue-200 dark:border-blue-800",
    text: "text-blue-800 dark:text-blue-200",
    iconColor: "text-blue-500",
  },
  warning: {
    icon: AlertTriangle,
    bg: "bg-amber-50 dark:bg-amber-950/30",
    border: "border-amber-200 dark:border-amber-800",
    text: "text-amber-800 dark:text-amber-200",
    iconColor: "text-amber-500",
  },
  success: {
    icon: CheckCircle,
    bg: "bg-green-50 dark:bg-green-950/30",
    border: "border-green-200 dark:border-green-800",
    text: "text-green-800 dark:text-green-200",
    iconColor: "text-green-500",
  },
};

export default function Callout({
  variant = "info",
  title,
  children,
}: {
  variant?: keyof typeof variants;
  title?: string;
  children: ReactNode;
}) {
  const v = variants[variant];
  const Icon = v.icon;

  return (
    <div className={`${v.bg} ${v.border} border rounded-lg p-4 my-4`}>
      <div className="flex gap-3">
        <Icon className={`w-5 h-5 mt-0.5 shrink-0 ${v.iconColor}`} />
        <div className={v.text}>
          {title && <p className="font-medium mb-1">{title}</p>}
          <div className="text-sm">{children}</div>
        </div>
      </div>
    </div>
  );
}
