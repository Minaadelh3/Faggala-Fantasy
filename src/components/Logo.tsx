type LogoProps = {
  variant?: 'full' | 'mark';
  tone?: 'light' | 'dark' | 'gold';
  className?: string;
};

/** The authoritative Faggala Fantasy artwork. Never redraw or recolor this mark. */
export default function Logo({ variant = 'full', className = '' }: LogoProps) {
  return <img src="/Logo.svg" alt="Faggala Fantasy" className={`block object-contain ${variant === 'mark' ? 'object-top' : ''} ${className}`} />;
}
