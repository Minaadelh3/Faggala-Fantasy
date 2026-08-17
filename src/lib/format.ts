export const cairoDate=(value:string,withTime=true)=>new Intl.DateTimeFormat('en-EG',{timeZone:'Africa/Cairo',weekday:'short',day:'numeric',month:'short',...(withTime?{hour:'numeric',minute:'2-digit'}:{})}).format(new Date(value));
export const money=(value:number|string)=>Number(value).toFixed(1);
export const initials=(name:string)=>name.split(/\s+/).slice(0,2).map((part)=>part[0]).join('').toUpperCase();
export const deadlineOpen=(deadline?:string)=>Boolean(deadline&&Date.now()<new Date(deadline).getTime());
