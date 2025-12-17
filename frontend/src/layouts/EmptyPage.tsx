import {
  Box,
  Card,
  CardContent,
  Typography,
} from '@mui/material';

const EmptyPage = (props: { header?: any, message: string }) => {
  const { header, message } = props;
  return (
    <Box sx={{ width: 1 }}>
      {header}
      <Card sx={{ width: 1 }}>
        <CardContent sx={{ display: 'flex', justifyContent: 'center', alignItems: 'center' }}>
          <Typography variant="body1">
            {message}
          </Typography>
        </CardContent>
      </Card>
    </Box>
  )
}
export default EmptyPage;