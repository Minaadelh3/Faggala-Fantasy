export default function ArcDivider({ className = '' }: { className?: string }) {
  return (
    <svg viewBox="0 0 200 16" className={`w-16 h-3 ${className}`} aria-hidden="true">
      <path
        d="M2 14 C 60 2, 140 2, 198 14"
        fill="none"
        stroke="#DAA520"
        strokeWidth="3"
        strokeLinecap="round"
      />
    </svg>
  );
}
