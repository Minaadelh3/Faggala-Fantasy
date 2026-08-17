import type { LucideIcon } from 'lucide-react';

type StatCardProps = {
  label: string;
  value: string;
  sublabel?: string;
  icon: LucideIcon;
  accent?: boolean;
};

export default function StatCard({ label, value, sublabel, icon: Icon, accent }: StatCardProps) {
  return (
    <div
      className={`relative overflow-hidden rounded-xl border p-4 ${
        accent
          ? 'bg-midnight-800 border-gold/40 text-white'
          : 'bg-white border-mist text-midnight-900'
      }`}
    >
      <div className="flex items-start justify-between">
        <div>
          <p className={`text-xs font-medium uppercase tracking-wide ${accent ? 'text-mist/70' : 'text-midnight-600/70'}`}>
            {label}
          </p>
          <p className="mt-1 text-2xl font-display font-bold">{value}</p>
          {sublabel && (
            <p className={`mt-1 text-xs ${accent ? 'text-gold-light' : 'text-gold-dim'}`}>{sublabel}</p>
          )}
        </div>
        <Icon className={accent ? 'text-gold' : 'text-midnight-600'} size={20} strokeWidth={2} />
      </div>
    </div>
  );
}
