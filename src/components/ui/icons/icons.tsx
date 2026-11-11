import React from "react";
import * as Pixel from "pixelarticons/react";

type IconProps = React.SVGProps<SVGSVGElement> & { size?: number | string };

// Keep the app's semantic names stable while using the closest available pixel icon.
export const iconMap = {
  folder: Pixel.Folder,
  arrowUpRight: Pixel.ExternalLink,
  volume: Pixel.Volume2,
  microphone: Pixel.Mic,
  stop: Pixel.StopSolid,
  cursor: Pixel.CursorMinimal,
  shield: Pixel.Shield,
  noBackground: Pixel.Close,
  photoPlus: Pixel.Image2Plus,
  video: Pixel.Video,
  chevronUp: Pixel.ChevronUp,
  chevronDown: Pixel.ChevronDown,
  chevronLeft: Pixel.ChevronLeft,
  chevronRight: Pixel.ChevronRight,
  arrowLeft: Pixel.ArrowLeft,
  arrowRight: Pixel.ArrowRight,
  menu: Pixel.Menu,
  x: Pixel.Close,
  selector: Pixel.ChevronsVertical,
  dots: Pixel.MoreHorizontal,
  dotsVertical: Pixel.MoreVertical,
  eye: Pixel.Eye,
  eyeOff: Pixel.EyeOff,
  gripVertical: Pixel.DragAndDrop,
  minus: Pixel.Minus,
  plus: Pixel.Plus,
  layoutColumns: Pixel.TextColums,
  layoutRows: Pixel.Layout,
  layoutSidebarInactive: Pixel.Layout,
  alertCircle: Pixel.CircleInfo,
  circleCheck: (props: IconProps) => (
    <svg
      {...props}
      xmlns="http://www.w3.org/2000/svg"
      fill="currentColor"
      viewBox="0 0 24 24"
    >
      <path d="M18 22H6v-2h12v2ZM6 20H4v-2h2v2Zm14 0h-2v-2h2v2ZM4 18H2V6h2v12Zm18 0h-2V6h2v12Zm-11-2H9v-2h2v2Zm-2-2H7v-2h2v2Zm4 0h-2v-2h2v2Zm2-2h-2v-2h2v2Zm2-2h-2V8h2v2ZM6 6H4V4h2v2Zm14 0h-2V4h2v2Zm-2-2H6V2h12v2Z"></path>
    </svg>
  ),
  alertTriangle: Pixel.WarningDiamond,
  exclamationCircle: Pixel.WarningDiamond,
  circleCheckFilled: Pixel.CheckboxOn,
  infoCircle: Pixel.CircleInfo,
  calendar: Pixel.Calendar,
  calendarWeek: Pixel.CalendarWeeks,
  list: Pixel.ListBox,
  calendarEvent: Pixel.CalendarText,
  calendarOff: Pixel.Calendar,
  coffee: Pixel.Coffee,
  clock: Pixel.Clock,
  logOut: Pixel.Logout,
  trash: Pixel.Trash,
  photo: Pixel.Image,
  add: Pixel.Plus,
  edit: Pixel.Pencil,
  save: Pixel.Save,
  delete: Pixel.Trash,
  search: Pixel.Search,
  settings: Pixel.Settings2,
  user: Pixel.User,
  users: Pixel.Users,
  building: Pixel.Building,
  buildingStore: Pixel.Store,
  mail: Pixel.Mail,
  lock: Pixel.Lock,
  phone: Pixel.Phone,
  bell: Pixel.Bell,
  palette: Pixel.ColorsSwatch,
  sun: Pixel.Sun,
  moon: Pixel.Moon,
  plug: Pixel.Plug,
  creditCard: Pixel.CreditCard,
  notes: Pixel.Notes,
  notesFilled: Pixel.NotesSharp,
  forms: Pixel.FileText,
  tag: Pixel.Label,
  chartBar: Pixel.ChartBarBig,
  bolt: Pixel.Zap,
  dashboard: Pixel.Layout,
  dashboardFilled: Pixel.LayoutSolid,
  copy: Pixel.Copy,
  qrCode: Pixel.QrCode,
  download: Pixel.Download,
  refresh: Pixel.Refresh,
  play: Pixel.Play,
  pause: Pixel.Pause,
  restart: Pixel.Repeat,
  share: Pixel.Share,
  send: Pixel.Send,
  textSize: Pixel.TextStartT,
  check: Pixel.Check,
  info: Pixel.CircleInfo,
  help: Pixel.CircleQuestion,
  loader: Pixel.Loading,
  wifiOff: Pixel.Wifi,
  browser: Pixel.WindowFrame,
  world: Pixel.Globe,
  brandChrome: Pixel.GoogleChrome,
  brandEdge: Pixel.Globe,
  brandFirefox: Pixel.Globe,
  brandOpera: Pixel.Globe,
  brandSafari: Pixel.Globe,
  deviceDesktop: Pixel.Monitor,
  deviceLaptop: Pixel.Laptop,
  deviceMobile: Pixel.Smartphone,
  home: Pixel.Home,
  circleNumber1: Pixel.Circle,
  circleNumber2: Pixel.Circle,
  cursorGrow: Pixel.ArrowsHorizontal,
  record: (props: IconProps) => (
    <svg
      {...props}
      xmlns="http://www.w3.org/2000/svg"
      fill="currentColor"
      viewBox="0 0 24 24"
    >
      <path d="M16 22H8V20H16V22ZM8 20H6V18H8V20ZM18 20H16V18H18V20ZM6 18H4V16H6V18ZM20 18H18V16H20V18ZM4 16H2V8H4V16ZM14 10H16V14H14V16H10V14H8V10H10V8H14V10ZM22 16H20V8H22V16ZM6 8H4V6H6V8ZM20 8H18V6H20V8ZM8 6H6V4H8V6ZM18 6H16V4H18V6ZM16 4H8V2H16V4Z"></path>
    </svg>)
} as const;

export type AppIconName = keyof typeof iconMap;

interface WrappedIconProps extends Omit<IconProps, "name"> {
  name: AppIconName | React.ComponentType<IconProps>;
}

export default function Icon({ name, size = 24, ...props }: WrappedIconProps) {
  const IconComponent: React.ComponentType<IconProps> =
    typeof name === "string" ? (iconMap[name] ?? Pixel.CircleQuestion) : name;
  return <IconComponent width={size} height={size} {...props} />;
}
