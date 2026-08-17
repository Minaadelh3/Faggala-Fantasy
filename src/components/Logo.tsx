type LogoProps = {
  variant?: 'full' | 'mark';
  tone?: 'light' | 'dark' | 'gold';
  className?: string;
};

/**
 * The Fantasy gateway mark: a cross-topped arch (heritage, trust)
 * framing an athlete in motion (speed, competition), cut through
 * by the gold energy arc (momentum, victory).
 */
export default function Logo({ variant = 'full', tone = 'light', className = '' }: LogoProps) {
  const ink = tone === 'dark' ? '#0D2737' : '#FFFFFF';
  const gold = '#DAA520';

  return (
    <div className={`flex flex-col items-center ${className}`}>
      <svg viewBox="0 0 120 130" className="w-full h-full" aria-hidden="true">
        {/* cross */}
        <path d="M60 4 v14 M53 11 h14" stroke={ink} strokeWidth="3.5" strokeLinecap="round" />
        {/* dome */}
        <path d="M40 30 Q60 6 80 30" fill="none" stroke={ink} strokeWidth="3.5" strokeLinecap="round" />
        {/* arch */}
        <path
          d="M22 118 V56 Q22 22 60 22 Q98 22 98 56 V118"
          fill="none"
          stroke={ink}
          strokeWidth="4"
          strokeLinecap="round"
        />
        <path
          d="M32 118 V58 Q32 32 60 32 Q88 32 88 58 V118"
          fill="none"
          stroke={ink}
          strokeWidth="2"
          opacity="0.5"
        />
        {/* runner: head */}
        <circle cx="60" cy="55" r="6" fill={ink} />
        {/* runner: body sweep */}
        <path
          d="M60 61 C58 72 44 78 40 92"
          fill="none"
          stroke={ink}
          strokeWidth="6"
          strokeLinecap="round"
        />
        <path
          d="M60 61 C68 70 78 68 84 58"
          fill="none"
          stroke={ink}
          strokeWidth="6"
          strokeLinecap="round"
        />
        {/* gold energy arc */}
        <path
          d="M36 96 C52 88 70 84 90 66"
          fill="none"
          stroke={gold}
          strokeWidth="5"
          strokeLinecap="round"
        />
      </svg>
      {variant === 'full' && (
        <span
          className="font-display italic font-extrabold tracking-tight -mt-1"
          style={{ color: ink, fontSize: '1.1rem' }}
        >
          Fantasy
        </span>
      )}
    </div>
  );
}
